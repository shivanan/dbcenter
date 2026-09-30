"""Disposable loopback SSH fixture. Requires paramiko; never authenticates OS users."""
import pathlib
import select
import socket
import sys
import threading
import paramiko

root = pathlib.Path(sys.argv[1])
host_key = paramiko.RSAKey.generate(2048)
client_key = paramiko.RSAKey.generate(2048)
client_key.write_private_key_file(str(root / "key"))
(root / "key").chmod(0o600)
client_key.write_private_key_file(str(root / "encrypted-key"), password="fixture-password")
(root / "encrypted-key").chmod(0o600)


class Server(paramiko.ServerInterface):
    def __init__(self):
        self.targets = {}

    def get_allowed_auths(self, username):
        return "publickey,password"

    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "dbcenter_test" and key == client_key else paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == "dbcenter_test" and password == "fixture-password" else paramiko.AUTH_FAILED

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        host, port = destination
        if host != "fixture.internal" or port not in (15439, 27029, 16389, 18089):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.targets[channel_id] = ("127.0.0.1", port)
        return paramiko.OPEN_SUCCEEDED


def relay(channel, target):
    try:
        with socket.create_connection(target, timeout=10) as remote:
            remote.settimeout(None)
            while True:
                readable, _, _ = select.select([channel, remote], [], [], 30)
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is channel else channel).sendall(data)
    except (OSError, EOFError):
        pass
    finally:
        channel.close()


def serve(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    server = Server()
    try:
        transport.start_server(server=server)
        while transport.is_active():
            channel = transport.accept(1)
            if channel:
                threading.Thread(target=relay, args=(channel, server.targets[channel.chanid]), daemon=True).start()
    except (paramiko.SSHException, OSError, EOFError):
        pass
    finally:
        transport.close()


with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    wrong_key = paramiko.RSAKey.generate(2048)
    (root / "wrong-hosts").write_text(f"[127.0.0.1]:{listener.getsockname()[1]} {wrong_key.get_name()} {wrong_key.get_base64()}\n")
    (root / "port").write_text(str(listener.getsockname()[1]))
    while True:
        client, _ = listener.accept()
        threading.Thread(target=serve, args=(client,), daemon=True).start()
