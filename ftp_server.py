#!/usr/bin/env python3
"""Native Python 3 FTP Server.

Zero dependencies required (Works on Python 3.14+ without pip/pyftpdlib).
"""

import argparse
import os
import socket
import sys
import threading


def local_ip() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


class FTPServerThread(threading.Thread):
    def __init__(self, conn, addr, root_dir, username, password):
        super().__init__(daemon=True)
        self.conn = conn
        self.addr = addr
        self.root_dir = root_dir
        self.username = username
        self.password = password
        self.cwd = "/"
        self.pasv_sock = None
        self.authenticated = False

    def send(self, msg):
        self.conn.sendall(f"{msg}\r\n".encode("utf-8"))

    def resolve_path(self, path):
        if not path:
            return os.path.join(self.root_dir, self.cwd.lstrip("/"))
        if path.startswith("/"):
            target = os.path.join(self.root_dir, path.lstrip("/"))
        else:
            target = os.path.join(self.root_dir, self.cwd.lstrip("/"), path)
        real_target = os.path.realpath(target)
        if not real_target.startswith(self.root_dir):
            return self.root_dir
        return real_target

    def open_data_connection(self):
        if not self.pasv_sock:
            return None
        data_conn, _ = self.pasv_sock.accept()
        self.pasv_sock.close()
        self.pasv_sock = None
        return data_conn

    def run(self):
        self.send("220 Welcome to Native TVisualiser FTP Server")
        while True:
            try:
                data = self.conn.recv(1024).decode("utf-8", errors="ignore")
                if not data:
                    break
                for line in data.splitlines():
                    if not line.strip():
                        continue
                    parts = line.strip().split(" ", 1)
                    cmd = parts[0].upper()
                    arg = parts[1] if len(parts) > 1 else ""
                    self.handle_cmd(cmd, arg)
            except Exception:
                break
        self.conn.close()

    def handle_cmd(self, cmd, arg):
        if cmd == "USER":
            if self.username == "anonymous" or arg == self.username:
                self.send("331 Password required")
            else:
                self.send("530 Invalid username")
        elif cmd == "PASS":
            self.authenticated = True
            self.send("230 User logged in")
        elif not self.authenticated:
            self.send("530 Please log in with USER and PASS")
        elif cmd == "SYST":
            self.send("215 UNIX Type: L8")
        elif cmd == "PWD":
            self.send(f'257 "{self.cwd}" is current directory')
        elif cmd == "TYPE":
            self.send("200 Type set to " + arg)
        elif cmd == "PASV":
            self.pasv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.pasv_sock.bind((self.conn.getsockname()[0], 0))
            self.pasv_sock.listen(1)
            port = self.pasv_sock.getsockname()[1]
            ip_parts = local_ip().split(".")
            p1, p2 = port // 256, port % 256
            self.send(
                f"227 Entering Passive Mode ({','.join(ip_parts)},{p1},{p2})"
            )
        elif cmd in ("LIST", "NLST"):
            data_conn = self.open_data_connection()
            if not data_conn:
                self.send("425 Use PASV first")
                return
            self.send("150 Opening ASCII mode data connection for file list")
            target_dir = self.resolve_path(arg)
            lines = []
            try:
                for entry in os.listdir(target_dir):
                    full_path = os.path.join(target_dir, entry)
                    size = os.path.getsize(full_path)
                    is_dir = "d" if os.path.isdir(full_path) else "-"
                    lines.append(
                        f"{is_dir}rwxr-xr-x 1 owner group {size} Jan 1 00:00 {entry}"
                    )
            except Exception:
                pass
            data_conn.sendall(("\r\n".join(lines) + "\r\n").encode("utf-8"))
            data_conn.close()
            self.send("226 Transfer complete")
        elif cmd == "CWD":
            target = self.resolve_path(arg)
            if os.path.isdir(target):
                rel = os.path.relpath(target, self.root_dir)
                self.cwd = "/" if rel == "." else "/" + rel
                self.send("250 Directory successfully changed")
            else:
                self.send("550 Failed to change directory")
        elif cmd == "RETR":
            file_path = self.resolve_path(arg)
            if not os.path.isfile(file_path):
                self.send("550 File not found")
                return
            data_conn = self.open_data_connection()
            if not data_conn:
                self.send("425 Use PASV first")
                return
            self.send(f"150 Opening BINARY mode data connection for {arg}")
            try:
                with open(file_path, "rb") as f:
                    while chunk := f.read(65536):
                        data_conn.sendall(chunk)
            except Exception as e:
                print(f"Error streaming file: {e}")
            finally:
                data_conn.close()
            self.send("226 Transfer complete")
        elif cmd == "QUIT":
            self.send("221 Goodbye")
            self.conn.close()
        else:
            self.send("502 Command not implemented")


def main():
    parser = argparse.ArgumentParser(
        description="Run a native FTP server for Apple TV / TVisualiser."
    )
    parser.add_argument("directory", help="Directory containing media files")
    parser.add_argument(
        "--port", type=int, default=2121, help="FTP port (default: 2121)"
    )
    parser.add_argument("--username", default="anonymous", help="FTP username")
    parser.add_argument("--password", default="anonymous", help="FTP password")
    args = parser.parse_args()

    root_dir = os.path.realpath(os.path.expanduser(args.directory))
    if not os.path.isdir(root_dir):
        print(f"Error: Directory '{root_dir}' does not exist.")
        sys.exit(1)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", args.port))
    s.listen(5)

    # Get local IP address for TVisualiser
    print("=" * 60)
    print(f"Native FTP Server running!")
    print(f"Serving Folder: {root_dir}")
    print(f"Connect in TVisualiser using: {local_ip()}:{args.port}")
    print("=" * 60)

    try:
        while True:
            conn, addr = s.accept()
            thread = FTPServerThread(
                conn, addr, root_dir, args.username, args.password
            )
            thread.start()
    except KeyboardInterrupt:
        print("\nStopping FTP Server...")
    finally:
        s.close()


if __name__ == "__main__":
    main()