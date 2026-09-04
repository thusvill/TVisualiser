import socket
import struct
import subprocess
import time
import sys
import os
import tempfile
import urllib.request
import io
import math
from PIL import Image

TARGET_IP = "127.0.0.1"
RTSP_PORT = 5000
UDP_PORT = 6000
FRAMES_PER_PACKET = 352
CHUNK_SIZE = FRAMES_PER_PACKET * 2 * 2  # stereo 16-bit PCM bytes

def pack_daap_tag(code, value):
    """Encodes a DAAP tag (FourCC + 4-byte length + payload)."""
    if isinstance(value, str):
        val_bytes = value.encode('utf-8')
    elif isinstance(value, bytes):
        val_bytes = value
    else:
        return b""
    return code.encode('ascii') + struct.pack('>I', len(val_bytes)) + val_bytes

def normalize_artwork(raw_bytes):
    """Compresses and converts raw artwork to a standard 600x600 JPEG."""
    if not raw_bytes:
        return None
    try:
        image = Image.open(io.BytesIO(raw_bytes))
        image = image.convert("RGB")
        image.thumbnail((600, 600))
        output = io.BytesIO()
        image.save(output, format="JPEG", quality=80)
        return output.getvalue()
    except Exception as e:
        print(f"[!] Artwork optimization warning: {e}")
        return raw_bytes

def get_now_playing_macos():
    """Queries macOS Apple Music and Spotify via AppleScript for active playback."""
    script_music = '''
    tell application "System Events"
        if (name of processes) contains "Music" then
            tell application "Music"
                if player state is playing then
                    set tTitle to name of current track
                    set tArtist to artist of current track
                    set tAlbum to album of current track
                    return tTitle & "||" & tArtist & "||" & tAlbum & "||Music"
                end if
            end tell
        end if
    end tell
    return ""
    '''
    
    script_spotify = '''
    tell application "System Events"
        if (name of processes) contains "Spotify" then
            tell application "Spotify"
                if player state is playing then
                    set tTitle to name of current track
                    set tArtist to artist of current track
                    set tAlbum to album of current track
                    return tTitle & "||" & tArtist & "||" & tAlbum & "||Spotify"
                end if
            end tell
        end if
    end tell
    return ""
    '''

    for script in [script_music, script_spotify]:
        try:
            res = subprocess.check_output(["osascript", "-e", script]).decode('utf-8').strip()
            if res and "||" in res:
                parts = res.split("||")
                return {
                    "title": parts[0],
                    "artist": parts[1],
                    "album": parts[2],
                    "source": parts[3]
                }
        except Exception:
            pass
            
    return None

def extract_artwork_bytes(metadata):
    """Extracts raw cover art artwork from Apple Music or downloads it for Spotify."""
    source = metadata.get("source")
    raw_art = None
    
    # 1. Apple Music (Direct binary extract)
    if source == "Music":
        temp_art = os.path.join(tempfile.gettempdir(), "airplay_cover.jpg")
        script = f'''
        tell application "Music"
            if exists (raw data of artwork 1 of current track) then
                set srcBytes to raw data of artwork 1 of current track
                set fileName to "{temp_art}"
                set outFile to open for access file fileName with write permission
                set eof outFile to 0
                write srcBytes to outFile
                close access outFile
            end if
        end tell
        '''
        try:
            subprocess.run(["osascript", "-e", script], check=True)
            if os.path.exists(temp_art):
                with open(temp_art, "rb") as f:
                    raw_art = f.read()
        except Exception:
            pass

    # 2. Spotify (Fetch image from Spotify URL)
    elif source == "Spotify":
        script = 'tell application "Spotify" to return artwork url of current track'
        try:
            art_url = subprocess.check_output(["osascript", "-e", script]).decode('utf-8').strip()
            if art_url.startswith("http"):
                req = urllib.request.Request(art_url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req) as response:
                    raw_art = response.read()
        except Exception:
            pass
            
    return normalize_artwork(raw_art)

class AirPlayBridge:
    def __init__(self):
        self.rtsp_sock = None
        self.current_track = None
        self.sequence = 0
        self.timestamp = 0
        self.server_audio_port = None
        self.session_id = None
        self.cseq = 0

    def next_cseq(self):
        self.cseq += 1
        return self.cseq

    def receive_response(self):
        """Read one complete RTSP response, including an optional body."""
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.rtsp_sock.recv(4096)
            if not chunk:
                break
            response += chunk
        if not response:
            raise RuntimeError("RTSP receiver closed the connection")
        header, body = response.split(b"\r\n\r\n", 1)
        lines = header.decode("utf-8", errors="replace").split("\r\n")
        content_length = 0
        for line in lines:
            if line.lower().startswith("content-length:"):
                content_length = int(line.split(":", 1)[1].strip())
        while len(body) < content_length:
            chunk = self.rtsp_sock.recv(4096)
            if not chunk:
                break
            body += chunk
        for line in lines:
            if line.lower().startswith("session:"):
                self.session_id = line.split(":", 1)[1].strip().split(";", 1)[0]
        if not lines[0].startswith("RTSP/1.0 200"):
            raise RuntimeError(f"RAOP receiver rejected request: {lines[0]}")
        return lines, body

    def start_session(self, metadata):
        """Executes a classic RAOP RTSP initialization flow that closely matches real Apple sender behavior."""
        self.rtsp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.rtsp_sock.settimeout(5)
        self.rtsp_sock.connect((TARGET_IP, RTSP_PORT))
        print(f"[*] RAOP RTSP connected ({TARGET_IP}:{RTSP_PORT})")

        # 1. OPTIONS
        options_cseq = self.next_cseq()
        self.rtsp_sock.sendall(
            f"OPTIONS * RTSP/1.0\r\nCSeq: {options_cseq}\r\nUser-Agent: AirPlay/320.20\r\n\r\n".encode()
        )
        self.receive_response()

        # 2. ANNOUNCE with classic RAOP SDP fields
        sdp = (
            "v=0\r\n"
            "o=iTunes 1 0 IN IP4 127.0.0.1\r\n"
            "s=AirTunes\r\n"
            "c=IN IP4 127.0.0.1\r\n"
            "t=0 0\r\n"
            "m=audio 0 RTP/AVP 96\r\n"
            "a=rtpmap:96 L16/44100/2\r\n"
            "a=min-latency:11025\r\n"
        ).encode()
        announce_cseq = self.next_cseq()
        announce = (
            f"ANNOUNCE rtsp://127.0.0.1/stream RTSP/1.0\r\n"
            f"CSeq: {announce_cseq}\r\n"
            "Content-Type: application/sdp\r\n"
            f"Content-Length: {len(sdp)}\r\n\r\n".encode() + sdp
        )
        self.rtsp_sock.sendall(announce)
        self.receive_response()

        # 3. SETUP: keep the transport closer to a real sender than the bare minimum.
        setup_cseq = self.next_cseq()
        setup_req = (
            f"SETUP rtsp://127.0.0.1/stream RTSP/1.0\r\n"
            f"CSeq: {setup_cseq}\r\n"
            "Transport: RTP/AVP/UDP;unicast;mode=record;interleaved=0-1;control_port=6001;timing_port=6002\r\n"
            "User-Agent: AirPlay/320.20\r\n\r\n"
        )
        self.rtsp_sock.sendall(setup_req.encode())
        setup_lines, _ = self.receive_response()
        for line in setup_lines:
            if line.lower().startswith("transport:") and "server_port=" in line:
                self.server_audio_port = int(line.split("server_port=", 1)[1].split(";", 1)[0])
        if not self.server_audio_port:
            raise RuntimeError("RAOP receiver did not return server_port")

        # 4. Initial metadata and state update, then record mode.
        self.send_metadata(metadata)
        self.send_keepalive(body=b"volume: 0.0\r\n")

        record_cseq = self.next_cseq()
        record_request = (
            f"RECORD rtsp://127.0.0.1/stream RTSP/1.0\r\n"
            f"CSeq: {record_cseq}\r\n"
            f"Session: {self.session_id or '0'}\r\n"
            "Range: npt=0-\r\n\r\n"
        )
        self.rtsp_sock.sendall(record_request.encode())
        self.receive_response()

    def send_keepalive(self, body: bytes):
        if not self.session_id:
            return
        cseq = self.next_cseq()
        header = (
            "SET_PARAMETER rtsp://127.0.0.1/stream RTSP/1.0\r\n"
            f"CSeq: {cseq}\r\n"
            f"Session: {self.session_id}\r\n"
            "Content-Type: text/parameters\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        )
        self.rtsp_sock.sendall(header.encode() + body)
        self.receive_response()

    def send_playback_command(self, method: str):
        if not self.session_id:
            return
        cseq = self.next_cseq()
        command = (
            f"{method} rtsp://127.0.0.1/stream RTSP/1.0\r\n"
            f"CSeq: {cseq}\r\n"
            f"Session: {self.session_id}\r\n"
            "Range: npt=0-\r\n\r\n"
        )
        self.rtsp_sock.sendall(command.encode())
        self.receive_response()

    def send_metadata(self, metadata):
        """Sends track title, artist, album, duration, and artwork using DAAP-style metadata."""
        artwork = extract_artwork_bytes(metadata)
        duration_ms = int(metadata.get("duration_ms", 210000))

        daap_payload = (
            pack_daap_tag('minm', metadata["title"]) +
            pack_daap_tag('asar', metadata["artist"]) +
            pack_daap_tag('asal', metadata["album"]) +
            pack_daap_tag('mper', struct.pack('>I', duration_ms))
        )

        if artwork:
            daap_payload += pack_daap_tag('covr', artwork)
            print(f"[*] Artwork attached ({len(artwork)} bytes)")

        cseq = self.next_cseq()
        session_line = f"Session: {self.session_id}\r\n" if self.session_id else ""
        header = (
            "SET_PARAMETER rtsp://127.0.0.1/stream RTSP/1.0\r\n"
            f"CSeq: {cseq}\r\n"
            + session_line
            + "Content-Type: application/x-dmap-tagged\r\n"
            + f"Content-Length: {len(daap_payload)}\r\n\r\n"
        )
        self.rtsp_sock.sendall(header.encode() + daap_payload)
        self.receive_response()
        print(f"[*] Now Playing on TV: '{metadata['title']}' by '{metadata['artist']}'")

def generate_tone_pcm(sample_rate=44100, frequency=440.0, duration_seconds=0.1):
    """Generate a stereo 16-bit little-endian tone for classic RAOP sender testing."""
    frame_count = int(sample_rate * duration_seconds)
    stereo = bytearray()
    for i in range(frame_count):
        sample = int(32767 * math.sin(2 * math.pi * frequency * i / sample_rate))
        stereo.extend(struct.pack("<h", sample))
        stereo.extend(struct.pack("<h", sample))
    return bytes(stereo)


def run_auto_bridge():
    bridge = AirPlayBridge()
    source_mode = os.environ.get("TVISUALISER_SOURCE", "system").lower()

    active_media = get_now_playing_macos() if source_mode == "system" else None
    if not active_media:
        active_media = {
            "title": "AirPlay Test Tone",
            "artist": "TVisualiser",
            "album": "Classic RAOP",
            "source": "simulated",
            "duration_ms": 210000
        }
        print("[*] No system media detected. Falling back to synthetic test tone.")
    else:
        print("[*] Waiting for macOS audio playback (Apple Music / Spotify)...")

    bridge.start_session(active_media)
    bridge.current_track = active_media["title"]

    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    process = None

    if source_mode == "system" and get_now_playing_macos():
        ffmpeg_cmd = [
            "ffmpeg", "-loglevel", "quiet",
            "-f", "avfoundation", "-i", ":0",
            "-f", "s16le", "-ar", "44100", "-ac", "2", "pipe:1"
        ]
        process = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    last_check_time = time.time()
    transport_toggle = 0

    try:
        while True:
            if process is not None:
                pcm_chunk = process.stdout.read(CHUNK_SIZE)
                if not pcm_chunk:
                    break
            else:
                pcm_chunk = generate_tone_pcm(duration_seconds=0.1)

            sample_count = len(pcm_chunk) // 2
            samples = struct.unpack(f"<{sample_count}h", pcm_chunk[:sample_count * 2])
            payload = struct.pack(f">{sample_count}h", *samples)
            header = struct.pack(">BBHII", 0x80, 0xE0, bridge.sequence, bridge.timestamp, 0x12345678)
            udp_sock.sendto(header + payload, (TARGET_IP, bridge.server_audio_port))
            bridge.sequence = (bridge.sequence + 1) & 0xffff
            bridge.timestamp = (bridge.timestamp + len(samples) // 2) & 0xffffffff

            if time.time() - last_check_time > 2.0:
                last_check_time = time.time()
                now_playing = get_now_playing_macos()
                if now_playing and now_playing["title"] != bridge.current_track:
                    print(f"[*] Song change detected!")
                    bridge.current_track = now_playing["title"]
                    bridge.send_metadata(now_playing)
                elif not now_playing:
                    transport_toggle += 1
                    if transport_toggle % 2 == 0:
                        bridge.send_playback_command("PAUSE")
                    else:
                        bridge.send_playback_command("PLAY")

    except KeyboardInterrupt:
        print("\n[*] Bridge stopped.")
    finally:
        if process is not None:
            process.terminate()
        udp_sock.close()
        if bridge.rtsp_sock:
            bridge.rtsp_sock.close()

if __name__ == "__main__":
    run_auto_bridge()