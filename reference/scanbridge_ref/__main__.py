"""python -m scanbridge_ref [--host 127.0.0.1] [--port 8766]"""

import argparse

from . import __version__
from .server import make_server


def main():
    parser = argparse.ArgumentParser(prog="scanbridge_ref",
                                     description="Reference Dossiary scan helper with fake scanners.")
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on (default 127.0.0.1; keep it local)")
    parser.add_argument("--port", type=int, default=8766, help="port (default 8766)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args()
    server = make_server(args.host, args.port)
    print(f"Reference scan helper on http://{args.host}:{args.port} (fake scanners). Ctrl+C stops it.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
