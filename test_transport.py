"""Host-only MPEG-TS/TCP smoke test. Does NOT validate any iOS system hook."""
import json
import pathlib
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "requires ffmpeg + ffprobe")
class TransportTest(unittest.TestCase):
    def test_h264_aac_over_fragmented_tcp(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "received.ts"
            listener = socket.socket()
            self.addCleanup(listener.close)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(10)
            errors = []

            def receive():
                try:
                    with listener.accept()[0] as client, path.open("wb") as output:
                        client.settimeout(10)
                        while True:
                            data = client.recv(137)  # Deliberately split TS packets.
                            if not data:
                                break
                            output.write(data)
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=receive, daemon=True)
            thread.start()
            port = listener.getsockname()[1]
            result = subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc2=size=360x640:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000",
                "-t", "2", "-c:v", "libx264", "-preset", "ultrafast",
                "-tune", "zerolatency", "-bf", "0", "-g", "30",
                "-c:a", "aac", "-b:a", "128k", "-f", "mpegts",
                f"tcp://127.0.0.1:{port}",
            ], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            thread.join(15)
            self.assertFalse(thread.is_alive())
            self.assertFalse(errors, errors)
            raw = path.read_bytes()
            self.assertGreater(len(raw), 188 * 10)
            self.assertEqual(len(raw) % 188, 0)
            self.assertTrue(all(raw[i] == 0x47 for i in range(0, len(raw), 188)))
            probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams",
                "-of", "json", str(path)], capture_output=True, text=True, check=True)
            streams = json.loads(probe.stdout)["streams"]
            self.assertEqual({s["codec_name"] for s in streams}, {"h264", "aac"})
            audio = next(s for s in streams if s["codec_type"] == "audio")
            self.assertEqual(audio["sample_rate"], "48000")


if __name__ == "__main__":
    unittest.main(verbosity=2)
