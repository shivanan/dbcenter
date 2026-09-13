#include "CDBDrivers.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <sys/time.h>
#define LIMIT 10000
struct DBConnection { int kind; void *lib; void *handle; void *env; };
static void *library(const char *name) {
    const char *roots[] = {"/opt/homebrew/lib", "/usr/local/lib", "/opt/homebrew/opt/libpq/lib", "/usr/local/opt/libpq/lib", NULL};
    char path[512];
    for(int i=0; roots[i]; i++) { snprintf(path,sizeof(path),"%s/%s",roots[i],name); void *p=dlopen(path,RTLD_NOW|RTLD_LOCAL); if(p)return p; }
    return dlopen(name,RTLD_NOW|RTLD_LOCAL);
}
#define FN(ret,name,args) ret (*name) args = (ret (*) args)dlsym(c->lib,#name)
#define NEED(name) if(!name){ *error=strdup("Installed driver is incompatible: missing " #name); db_close(c); return NULL; }
static char *diagnostic(DBConnection *c, short type, void *handle) {
    FN(short,SQLGetDiagRec,(short,void*,short,unsigned char*,int*,unsigned char*,short,short*));
    unsigned char state[6]={0}, message[2048]={0}; int native=0; short size=0;
    if(SQLGetDiagRec && SQLGetDiagRec(type,handle,1,state,&native,message,2048,&size)>=0) return strdup((char*)message);
    return strdup("ODBC operation failed.");
}
DBConnection *db_open(int kind,const char *connection,const char *host,int port,char **error) {
    DBConnection *c=calloc(1,sizeof(*c)); c->kind=kind;
    const char *libs[]={"libpq.dylib","libodbc.dylib","libmongoc-1.0.dylib","libhiredis.dylib"};
    c->lib=library(libs[kind]);
    if(!c->lib && kind==2)c->lib=library("libmongoc2.dylib");
    if(!c->lib){ const char *tips[]={"Postgres driver missing. Install with: brew install libpq", "SQL Server driver missing. Install unixodbc and Microsoft ODBC Driver 18 (see README).", "MongoDB driver missing. Install with: brew install mongo-c-driver", "Redis driver missing. Install with: brew install hiredis"}; *error=strdup(tips[kind]); free(c); return NULL; }
    if(kind==0){
        FN(void*,PQconnectdb,(const char*)); FN(int,PQstatus,(void*)); FN(char*,PQerrorMessage,(void*));
        NEED(PQconnectdb); NEED(PQstatus); NEED(PQerrorMessage);
        c->handle=PQconnectdb(connection);
        if(!c->handle || PQstatus(c->handle)!=0){*error=strdup(c->handle?PQerrorMessage(c->handle):"Cannot allocate Postgres connection"); db_close(c);return NULL;}
    }else if(kind==1){
        FN(short,SQLAllocHandle,(short,void*,void**)); FN(short,SQLSetEnvAttr,(void*,int,void*,int));
        FN(short,SQLSetConnectAttr,(void*,int,void*,int));
        FN(short,SQLDriverConnect,(void*,void*,const unsigned char*,short,unsigned char*,short,short*,unsigned short));
        NEED(SQLAllocHandle); NEED(SQLSetEnvAttr); NEED(SQLDriverConnect); NEED(SQLSetConnectAttr);
        if(SQLAllocHandle(1,NULL,&c->env)<0 || SQLSetEnvAttr(c->env,200,(void*)3,0)<0 || SQLAllocHandle(2,c->env,&c->handle)<0){*error=strdup("Cannot initialize ODBC");db_close(c);return NULL;}
        SQLSetConnectAttr(c->handle,103,(void*)10,0);
        short rc=SQLDriverConnect(c->handle,NULL,(const unsigned char*)connection,-3,NULL,0,NULL,0);
        if(rc!=0 && rc!=1){*error=diagnostic(c,2,c->handle); db_close(c);return NULL;}
    }else if(kind==2){
        FN(void,mongoc_init,(void)); FN(void*,mongoc_client_new,(const char*)); NEED(mongoc_init);NEED(mongoc_client_new);
        // mongoc_init is idempotent; never clean up process-global state while other sessions exist.
        mongoc_init(); c->handle=mongoc_client_new(connection);
        if(!c->handle){*error=strdup("Invalid MongoDB connection URI");db_close(c);return NULL;}
    }else{
        FN(void*,redisConnectWithTimeout,(const char*,int,struct timeval)); FN(int,redisSetTimeout,(void*,struct timeval));
        NEED(redisConnectWithTimeout); NEED(redisSetTimeout);
        struct timeval timeout={10,0}; c->handle=redisConnectWithTimeout(host,port,timeout);
        if(!c->handle || *(int*)((char*)c->handle+sizeof(void*))){*error=strdup("Cannot connect to Redis. Check host, port, and server availability.");db_close(c);return NULL;}
        redisSetTimeout(c->handle,(struct timeval){30,0});
    }
    return c;
}
static DBResult *failure(DBResult *r,const char *message){r->error=strdup(message);return r;}
static void allocate(DBResult *r,int cols){ r->columns=cols; r->names=calloc(cols,sizeof(char*)); r->cells=calloc((size_t)LIMIT*cols,sizeof(char*)); }
// Stable hiredis reply ABI (1.x).
typedef struct Reply { int type; long long integer; double dval; size_t len; char *str; char vtype[4]; size_t elements; struct Reply **element; } Reply;
static char *reply_text(Reply *r){
    if(!r || r->type==4)return NULL;
    if(r->str)return strndup(r->str,r->len);
    char b[100]; if(r->type==3 || r->type==8)snprintf(b,sizeof(b),"%lld",r->integer); else if(r->type==7)snprintf(b,sizeof(b),"%.17g",r->dval); else snprintf(b,sizeof(b),"(%zu elements)",r->elements);
    return strdup(b);
}
static void redis_rows(DBResult *out,Reply *reply,const char *path){
    if(reply->elements){ for(size_t i=0;i<reply->elements;i++){char p[512];snprintf(p,sizeof(p),"%s%s%zu",path,*path?".":"",i);redis_rows(out,reply->element[i],p);}return; }
    if(out->rows>=LIMIT){out->truncated=1;return;} int row=out->rows++;
    out->cells[row*2]=strdup(*path?path:"0");out->cells[row*2+1]=reply_text(reply);
}
DBResult *db_query(DBConnection *c,const char *database,const char *query,int argc,const char **argv){
    DBResult *r=calloc(1,sizeof(*r));
    if(c->kind==0){
        FN(void*,PQexec,(void*,const char*)); FN(int,PQresultStatus,(void*)); FN(char*,PQresultErrorMessage,(void*)); FN(int,PQntuples,(void*)); FN(int,PQnfields,(void*)); FN(char*,PQfname,(void*,int)); FN(char*,PQgetvalue,(void*,int,int)); FN(int,PQgetisnull,(void*,int,int)); FN(char*,PQcmdTuples,(void*)); FN(void,PQclear,(void*));
        if(!PQexec||!PQresultStatus||!PQresultErrorMessage||!PQntuples||!PQnfields||!PQfname||!PQgetvalue||!PQgetisnull||!PQcmdTuples||!PQclear)return failure(r,"Incompatible libpq library");
        void *result=PQexec(c->handle,query);if(!result)return failure(r,"Postgres returned no result");
        int status=PQresultStatus(result);
        if(status!=1 && status!=2){failure(r,PQresultErrorMessage(result));PQclear(result);return r;}
        int count=PQntuples(result);r->rows=count>LIMIT?LIMIT:count;r->truncated=count>LIMIT;allocate(r,PQnfields(result));r->affected=atoll(PQcmdTuples(result));
        for(int col=0;col<r->columns;col++){r->names[col]=strdup(PQfname(result,col));for(int row=0;row<r->rows;row++)if(!PQgetisnull(result,row,col))r->cells[row*r->columns+col]=strdup(PQgetvalue(result,row,col));}
        PQclear(result);
    }else if(c->kind==1){
        FN(short,SQLAllocHandle,(short,void*,void**));FN(short,SQLFreeHandle,(short,void*));FN(short,SQLSetStmtAttr,(void*,int,void*,int));FN(short,SQLExecDirect,(void*,const unsigned char*,int));FN(short,SQLNumResultCols,(void*,short*));FN(short,SQLDescribeCol,(void*,unsigned short,unsigned char*,short,short*,short*,unsigned long*,short*,short*));FN(short,SQLFetch,(void*));FN(short,SQLGetData,(void*,unsigned short,short,void*,long,long*));FN(short,SQLRowCount,(void*,long*));
        if(!SQLAllocHandle||!SQLFreeHandle||!SQLSetStmtAttr||!SQLExecDirect||!SQLNumResultCols||!SQLDescribeCol||!SQLFetch||!SQLGetData||!SQLRowCount)return failure(r,"Incompatible ODBC library");
        void *s=NULL;if(SQLAllocHandle(3,c->handle,&s)<0)return failure(r,"Cannot allocate ODBC statement");SQLSetStmtAttr(s,0,(void*)30,0);
        short rc=SQLExecDirect(s,(const unsigned char*)query,-3);
        if(rc<0){r->error=diagnostic(c,3,s);SQLFreeHandle(3,s);return r;}
        short cols=0;SQLNumResultCols(s,&cols);allocate(r,cols);long affected=0;SQLRowCount(s,&affected);r->affected=affected;
        for(int i=0;i<cols;i++){unsigned char name[1024]={0};short n,t,scale,nullable;unsigned long size;SQLDescribeCol(s,i+1,name,1024,&n,&t,&size,&scale,&nullable);r->names[i]=strdup((char*)name);}
        while(cols>0 && (rc=SQLFetch(s))!=100){
            if(rc<0){r->error=diagnostic(c,3,s);break;}if(r->rows==LIMIT){r->truncated=1;break;}
            int row=r->rows++;
            for(int i=0;i<cols;i++){
                char *value=NULL;size_t used=0;long indicator=0;
                do{char buf[4096]={0};rc=SQLGetData(s,i+1,1,buf,sizeof(buf),&indicator);
                    if(indicator==-1)break;if(rc<0){r->error=diagnostic(c,3,s);break;}
                    size_t len=strnlen(buf,sizeof(buf)-1);value=realloc(value,used+len+1);memcpy(value+used,buf,len);used+=len;value[used]=0;
                }while(rc==1);
                r->cells[row*cols+i]=value;
            }if(r->error)break;
        }SQLFreeHandle(3,s);
    }else if(c->kind==2){
        FN(void*,bson_new_from_json,(const unsigned char*,long,void*));FN(void*,bson_new,(void));FN(void,bson_destroy,(void*));FN(char*,bson_as_relaxed_extended_json,(void*,size_t*));FN(void,bson_free,(void*));FN(_Bool,mongoc_client_command_simple,(void*,const char*,void*,void*,void*,void*));
        if(!bson_new_from_json||!bson_new||!bson_destroy||!bson_as_relaxed_extended_json||!bson_free||!mongoc_client_command_simple)return failure(r,"Incompatible MongoDB C driver");
        struct {uint32_t domain;uint32_t code;char message[504];} error={0};
        void *command=bson_new_from_json((const unsigned char*)query,-1,&error);if(!command)return failure(r,error.message);
        void *reply=bson_new();
        if(!mongoc_client_command_simple(c->handle,database,command,NULL,reply,&error))failure(r,error.message);
        else {char *json=bson_as_relaxed_extended_json(reply,NULL);r->json=strdup(json?json:"{}");if(json)bson_free(json);}
        bson_destroy(command);bson_destroy(reply);
    }else{
        FN(void*,redisCommandArgv,(void*,int,const char**,const size_t*));FN(void,freeReplyObject,(void*));
        if(!redisCommandArgv||!freeReplyObject)return failure(r,"Incompatible hiredis library");
        Reply *reply=redisCommandArgv(c->handle,argc,argv,NULL);
        if(!reply)return failure(r,"Redis connection closed or timed out. Reconnect before running another command.");
        if(reply->type==6)failure(r,reply->str);else{allocate(r,2);r->names[0]=strdup("Path");r->names[1]=strdup("Value");redis_rows(r,reply,"");}freeReplyObject(reply);
    }return r;
}
void db_close(DBConnection *c){
    if(!c)return;
    if(c->lib){
        if(c->kind==0){FN(void,PQfinish,(void*));if(PQfinish&&c->handle)PQfinish(c->handle);}
        else if(c->kind==1){FN(short,SQLDisconnect,(void*));FN(short,SQLFreeHandle,(short,void*));if(SQLDisconnect&&c->handle)SQLDisconnect(c->handle);if(SQLFreeHandle){if(c->handle)SQLFreeHandle(2,c->handle);if(c->env)SQLFreeHandle(1,c->env);}}
        else if(c->kind==2){FN(void,mongoc_client_destroy,(void*));if(mongoc_client_destroy&&c->handle)mongoc_client_destroy(c->handle);}
        else {FN(void,redisFree,(void*));if(redisFree&&c->handle)redisFree(c->handle);}
        // Keep driver code loaded: libmongoc maintains global initialization and TLS state.
    }free(c);
}
void db_result_free(DBResult *r){if(!r)return;for(int i=0;i<r->columns;i++)free(r->names[i]);for(int i=0;i<r->rows*r->columns;i++)free(r->cells[i]);free(r->names);free(r->cells);free(r->json);free(r->error);free(r);}
void db_string_free(char *s){free(s);}
