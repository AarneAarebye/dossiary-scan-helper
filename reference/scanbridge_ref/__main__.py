"""python -m scanbridge_ref [--host 127.0.0.1] [--port 8766]"""

import argparse

from . import __version__
from .server import make_server

LOOPBACK_HOSTS = ("127.0.0.1", "localhost")


def host_allowed(host):
    """Only loopback addresses: the protocol forbids listening on other interfaces."""
    return host in LOOPBACK_HOSTS


def main():
    parser = argparse.ArgumentParser(prog="scanbridge_ref",
                                     description="Reference Dossiary scan helper with fake scanners.")
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on: 127.0.0.1 (default) or localhost")
    parser.add_argument("--port", type=int, default=8766, help="port (default 8766)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args()
    if not host_allowed(args.host):
        parser.error(f"--host must be 127.0.0.1 or localhost, not {args.host!r}: "
                     "the helper may only listen on this computer")  # exits with status 2
    server = make_server(args.host, args.port)
    print(f"Reference scan helper on http://{args.host}:{args.port} (fake scanners, pairing code 000000). "
          "Ctrl+C stops it.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
