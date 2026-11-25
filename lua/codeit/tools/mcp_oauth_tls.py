"""Transport for the HTTPS loopback callback; OAuth validation stays in Lua."""

import base64
import os
import queue
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time


def main():
    host, port, cert_host = sys.argv[1:4]
    cert, key = (os.environ.get('CODEIT_MCP_OAUTH_TLS_' + name) for name in ('CERT', 'KEY'))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    try:
        if cert and key:
            context.load_cert_chain(cert, key, password='')
        elif not cert and not key:
            with tempfile.TemporaryDirectory(prefix='codeit-oauth-') as directory:
                cert, key = (os.path.join(directory, name) for name in ('cert.pem', 'key.pem'))
                san = ('DNS:' if cert_host == 'localhost' else 'IP:') + cert_host
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                                '-days', '1', '-subj', '/CN=' + cert_host, '-addext', 'subjectAltName=' + san,
                                '-keyout', key, '-out', cert], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=8)
                context.load_cert_chain(cert, key)
        else:
            raise ValueError('incomplete TLS configuration')
    except (OSError, ValueError, subprocess.SubprocessError):
        print('certificate_error', flush=True)
        return

    replies = queue.Queue(maxsize=1)

    def read_replies():
        for line in sys.stdin.buffer:
            replies.put(base64.b64decode(line))
        os._exit(0)  # Don't leave a listener running if Neovim exits unexpectedly.

    threading.Thread(target=read_replies, daemon=True).start()
    with socket.socket() as listener:
        try:
            if os.name != 'nt':
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            else:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            listener.bind((host, int(port)))
            listener.listen(8)
        except OSError:
            print('listen_error', flush=True)
            return
        print('ready ' + str(listener.getsockname()[1]), flush=True)
        while True:
            connection, _ = listener.accept()
            responded = False
            with connection:
                try:
                    connection.settimeout(3)
                    with context.wrap_socket(connection, server_side=True) as client:
                        deadline = time.monotonic() + 3
                        request = bytearray()
                        while b'\r\n\r\n' not in request and len(request) <= 8192:
                            client.settimeout(max(0.001, deadline - time.monotonic()))
                            chunk = client.recv(8196 - len(request))
                            if not chunk:
                                break
                            request.extend(chunk)
                            if time.monotonic() >= deadline:
                                break
                        if b'\r\n\r\n' not in request:
                            continue
                        print('request ' + base64.b64encode(request).decode('ascii'), flush=True)
                        response = replies.get()
                        responded = True
                        client.settimeout(3)
                        client.sendall(response)
                except OSError:
                    pass
            if responded:
                print('sent', flush=True)


if __name__ == '__main__':
    main()
