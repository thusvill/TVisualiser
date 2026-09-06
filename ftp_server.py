import argparse
import os
import socket
import sys
import threading
import time

def local_ip() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # doesn't actually send data, just determines route
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
        print(f"[+] New connection from {self.addr}")

    def send(self, msg):
        try:
            self.conn.sendall(f"{msg}\r\n".encode("utf-8"))
        except Exception as e:
            print(f"[-] Send error: {e}")

    def resolve_path(self, path):
        # Handle empty path (current directory)
        if not path:
            return os.path.join(self.root_dir, self.cwd.lstrip("/"))
        
        # Handle absolute paths
        if path.startswith("/"):
            target = os.path.join(self.root_dir, path.lstrip("/"))
        else:
            # Handle relative paths
            target = os.path.join(self.root_dir, self.cwd.lstrip("/"), path)
            
        # Security: Ensure we don't escape root_dir
        real_target = os.path.realpath(target)
        if not real_target.startswith(self.root_dir):
            return self.root_dir
        return real_target

    def open_data_connection(self):
        if not self.pasv_sock:
            return None
        
        print(f"[Server] Waiting for client to connect to data port...")
        try:
            # This is where it hangs if Firewall blocks the connection
            self.pasv_sock.settimeout(10.0) # Timeout after 10 seconds
            data_conn, _ = self.pasv_sock.accept()
            self.pasv_sock.close()
            self.pasv_sock = None
            print(f"[Server] Data connection established!")
            return data_conn
        except socket.timeout:
            print("[-] Data connection timed out (Check Firewall!)")
            self.pasv_sock.close()
            self.pasv_sock = None
            return None
        except Exception as e:
            print(f"[-] Data connection error: {e}")
            return None

    def run(self):
        self.send("220 Welcome to Native TVisualiser FTP Server")
        while True:
            try:
                # Set a timeout on recv to avoid hanging indefinitely if client disconnects
                self.conn.settimeout(60.0)
                data = self.conn.recv(1024).decode("utf-8", errors="ignore").strip()
                if not data:
                    break
                
                # FTP commands can be stacked or malformed, split carefully
                # Simple heuristic: split by space, take first as cmd, rest as arg
                parts = data.split(" ", 1)
                cmd = parts[0].upper()
                arg = parts[1] if len(parts) > 1 else ""
                
                print(f"[Client -> Server] {cmd} {arg}")
                self.handle_cmd(cmd, arg)
            except socket.timeout:
                print(f"[-] Connection timed out for {self.addr}")
                break
            except Exception as e:
                print(f"[-] Connection error: {e}")
                break
        self.conn.close()
        print(f"[-] Connection closed for {self.addr}")

    def handle_cmd(self, cmd, arg):
        if cmd == "USER":
            # Accept any user for simplicity or check specific username
            if self.username == "anonymous" or arg == self.username:
                self.send("331 Password required")
            else:
                self.send("530 Invalid username")
                
        elif cmd == "PASS":
            # In a real server, check self.password here
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
            # Allow reusing the address to avoid "Address already in use" errors
            self.pasv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.pasv_sock.bind((self.conn.getsockname()[0], 0))
            self.pasv_sock.listen(1)
            port = self.pasv_sock.getsockname()[1]
            
            # IMPORTANT: This IP must be reachable by the Apple TV
            ip = local_ip()
            ip_parts = ip.split(".")
            p1, p2 = port // 256, port % 256
            
            pasv_response = f"227 Entering Passive Mode ({','.join(ip_parts)},{p1},{p2})"
            print(f"[Server] {pasv_response}")
            self.send(pasv_response)
            
        elif cmd in ("LIST", "NLST", "MLSD"):
            print(f"[Server] Processing LIST for path: '{arg}'")
            data_conn = self.open_data_connection()
            if not data_conn:
                self.send("425 Use PASV first or connection failed")
                return
            
            self.send("150 Opening ASCII mode data connection for file list")
            
            target_dir = self.resolve_path(arg)
            lines = []
            try:
                if os.path.exists(target_dir):
                    for entry in os.listdir(target_dir):
                        full_path = os.path.join(target_dir, entry)
                        if cmd == "MLSD":
                            is_dir = os.path.isdir(full_path)
                            size = 0 if is_dir else os.path.getsize(full_path)
                            mtime = time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(full_path)))
                            type_fact = "dir" if is_dir else "file"
                            lines.append(f"type={type_fact};size={size};modify={mtime}; {entry}")
                        else:
                            size = os.path.getsize(full_path)
                            is_dir = "d" if os.path.isdir(full_path) else "-"
                            lines.append(f"{is_dir}rwxr-xr-x 1 owner group {size} Jan 1 00:00 {entry}")
                else:
                    print(f"[Server] Directory not found: {target_dir}")
            except Exception as e:
                print(f"[-] Error listing directory: {e}")
            
            list_data = "\r\n".join(lines) + "\r\n"
            try:
                data_conn.sendall(list_data.encode("utf-8"))
            except Exception as e:
                print(f"[-] Error sending list data: {e}")
            finally:
                data_conn.close()
            
            self.send("226 Transfer complete")
            
        elif cmd == "CWD":
            target = self.resolve_path(arg)
            if os.path.isdir(target):
                rel = os.path.relpath(target, self.root_dir)
                self.cwd = "/" if rel == "." else "/" + rel.replace("\\", "/")
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
                self.send("425 Use PASV first or connection failed")
                return
            
            self.send(f"150 Opening BINARY mode data connection for {arg} ({os.path.getsize(file_path)} bytes)")
            
            try:
                with open(file_path, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        data_conn.sendall(chunk)
            except Exception as e:
                print(f"[-] Error streaming file: {e}")
            finally:
                data_conn.close()
            
            self.send("226 Transfer complete")
            
        elif cmd == "REST":
            # We don't support true resume, just acknowledge from offset 0
            self.send("350 Restarting at 0. Send STORE or RETRIEVE.")

        elif cmd == "MLST":
            target = self.resolve_path(arg)
            if os.path.exists(target):
                is_dir = os.path.isdir(target)
                size = 0 if is_dir else os.path.getsize(target)
                mtime = time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(target)))
                type_fact = "dir" if is_dir else "file"
                name = os.path.basename(target.rstrip("/")) or "/"
                self.send(f"250-Listing {arg}")
                self.send(f" type={type_fact};size={size};modify={mtime}; {name}")
                self.send("250 End")
            else:
                self.send("550 Could not get file status")
                    
        elif cmd == "QUIT":
            self.send("221 Goodbye")
            self.conn.close()
            return
        elif cmd == "SIZE":
            target = self.resolve_path(arg)
            if os.path.isfile(target):
                self.send(f"213 {os.path.getsize(target)}")
            else:
                self.send("550 Could not get file size")
        else:
            # Fallback for unimplemented commands like FEAT, OPTS, etc.
            self.send("502 Command not implemented")

def main():
    parser = argparse.ArgumentParser(description="Run a native FTP server for Apple TV / TVisualiser.")
    parser.add_argument("directory", help="Directory containing media files")
    parser.add_argument("--port", type=int, default=2121, help="FTP port (default: 2121)")
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

    print("=" * 60)
    print(f"Native FTP Server running!")
    print(f"Serving Folder: {root_dir}")
    print(f"Connect in TVisualiser using: {local_ip()}:{args.port}")
    print("=" * 60)

    try:
        while True:
            conn, addr = s.accept()
            thread = FTPServerThread(conn, addr, root_dir, args.username, args.password)
            thread.start()
    except KeyboardInterrupt:
        print("\nStopping FTP Server...")
    finally:
        s.close()

if __name__ == "__main__":
    main()
