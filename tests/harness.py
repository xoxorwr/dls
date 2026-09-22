"""Reusable helpers for the DLS end-to-end test suite.

The tests drive the real ``dls`` binary over stdio using the LSP base
protocol (``Content-Length`` framed JSON-RPC).  One server process is
started per test class and shared by every test in that class: starting the
server and warming DCD's module cache is the most expensive part of a DLS
run, so reusing a process keeps the whole suite in the low seconds.

Usage from a test module::

    from harness import DlsTestCase

    class MyTests(DlsTestCase):
        PROJECT = {"app.d": "module app;\\n\\nvoid main() {}\\n"}

        def test_something(self):
            doc = self.open_doc("app.d")
            symbols = doc.document_symbols()
            self.assertIn("main", [symbol["name"] for symbol in symbols])

Positions are computed from the fixture text with :meth:`Doc.position`, which
takes a needle such as ``"st."`` and returns the LSP position right after it.
That avoids brittle hard-coded line/character pairs when fixtures change.
"""

from __future__ import annotations

import itertools
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from typing import Any, Callable, Iterable

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: Seconds to wait for a response before assuming the server hung.
DEFAULT_TIMEOUT = float(os.environ.get("DLS_TEST_TIMEOUT", "60"))

#: How much stderr to keep around for failure messages (lines).
STDERR_TAIL_LINES = 300

#: LSP completion kinds the server emits (mirrors ``kind_to_lsp`` in main.d).
KIND_TEXT = 1
KIND_METHOD = 2
KIND_FUNCTION = 3
KIND_CONSTRUCTOR = 4
KIND_FIELD = 5
KIND_VARIABLE = 6
KIND_CLASS = 7
KIND_INTERFACE = 8
KIND_MODULE = 9
KIND_PROPERTY = 10
KIND_ENUM = 13
KIND_KEYWORD = 14
KIND_FILE = 17
KIND_REFERENCE = 18
KIND_ENUM_MEMBER = 20
KIND_STRUCT = 22
KIND_TYPE_PARAMETER = 25


class DlsError(RuntimeError):
    """Base class for every failure raised by the harness."""


class ServerNotFound(DlsError):
    """The ``dls`` binary could not be located."""


class ServerDied(DlsError):
    """The server exited (or crashed) while a request was in flight."""


class ResponseTimeout(DlsError):
    """No response arrived before the timeout expired."""


class RequestError(DlsError):
    """The server answered with a JSON-RPC error object."""


def find_server() -> str:
    """Return the path to the ``dls`` binary, honouring ``DLS_SERVER``."""
    env = os.environ.get("DLS_SERVER")
    if env:
        if os.path.isfile(env) and os.access(env, os.X_OK):
            return os.path.abspath(env)
        raise ServerNotFound(f"DLS_SERVER points at a missing/executable-less file: {env}")

    candidates = [
        os.path.join(REPO_ROOT, "bin", "dls"),
        os.path.join(REPO_ROOT, "bin", "dls.exe"),
    ]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate

    raise ServerNotFound(
        "could not find the dls binary; build it with 'make dls' "
        "or point DLS_SERVER / --server at it"
    )


def path_to_uri(path: str) -> str:
    """Turn an absolute filesystem path into a ``file://`` URI."""
    return "file://" + os.path.abspath(path)


def write_text(path: str, text: str) -> None:
    """Write ``text`` to ``path`` atomically (through a temporary file).

    The server resolves imports by reading these files from disk.  A plain
    ``open(path, "w")`` truncates the file first, and a server that reads the
    path inside that window sees an empty module, caches it as an empty module
    and answers the completion that triggered the read with nothing.  Renaming
    a fully written temporary file into place is atomic, so a concurrent
    reader sees either the previous file or the complete new one, never a
    truncated one.
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def encode_message(message: dict[str, Any]) -> bytes:
    """Frame a JSON-RPC message with LSP's ``Content-Length`` header."""
    body = json.dumps(message).encode("utf-8")
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


def labels(items: Iterable[dict[str, Any]]) -> list[str]:
    """Return the completion labels of a completion item list."""
    return [item.get("label") for item in items]


def find_item(items: Iterable[dict[str, Any]], label: str) -> dict[str, Any]:
    """Return the first completion item with ``label`` or raise."""
    for item in items:
        if item.get("label") == label:
            return item
    raise AssertionError(f"no completion item labelled {label!r} in {labels(items)}")


class LspClient:
    """A minimal, synchronous LSP client for a single ``dls`` process."""

    def __init__(
        self,
        server: str,
        root: str,
        *,
        client_capabilities: dict[str, Any] | None = None,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> None:
        self.server = server
        self.root = os.path.abspath(root)
        self.timeout = timeout
        self.capabilities: dict[str, Any] = {}
        self.server_info: dict[str, Any] = {}
        self.initialize_result: dict[str, Any] | None = None

        self._ids = itertools.count(1)
        self._condition = threading.Condition()
        self._responses: dict[int, dict[str, Any]] = {}
        self._notifications: list[dict[str, Any]] = []
        self._stderr_lines: list[str] = []
        self._pending: dict[int, str] = {}
        self._reader_error: str | None = None
        self._closed = False

        env = dict(os.environ)
        # Keep the server's own logging quiet on machines where the test host
        # sets a debug flag inherited from a developer shell.
        env.setdefault("LD_LIBRARY_PATH", os.path.join(os.path.dirname(server)))

        self.process = subprocess.Popen(
            [server],
            cwd=self.root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self._stdout = self.process.stdout
        self._stdout_fd = self._stdout.fileno() if self._stdout else -1

        threading.Thread(target=self._read_stdout, name="dls-stdout", daemon=True).start()
        threading.Thread(target=self._read_stderr, name="dls-stderr", daemon=True).start()

        params = {
            "processId": os.getpid(),
            "rootPath": self.root,
            "rootUri": path_to_uri(self.root),
            # ClientCapabilities: the server reads
            # "workspace.didChangeWatchedFiles.dynamicRegistration" from here
            # to decide whether it can register a file watcher.
            "capabilities": client_capabilities or {},
        }
        try:
            result = self.request("initialize", params, timeout=max(timeout, 120.0))
        except Exception:
            # A half-started server must not be left behind for the next test.
            self.close()
            raise
        self.initialize_result = result
        self.capabilities = (result or {}).get("capabilities", {})
        self.server_info = (result or {}).get("serverInfo", {})
        self.notify("initialized", {})

    # -- transport ---------------------------------------------------------

    def _read_stdout(self) -> None:
        while True:
            try:
                message = self._read_message()
            except Exception as exc:  # pragma: no cover - transport level failure
                with self._condition:
                    self._reader_error = f"{type(exc).__name__}: {exc}"
                    self._condition.notify_all()
                message = None
            if message is None:
                with self._condition:
                    # stdout hit EOF: the server is gone (or shutting down).
                    self._closed = True
                    self._condition.notify_all()
                return
            self._dispatch(message)

    def _read_message(self) -> dict[str, Any] | None:
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            chunk = os.read(self._stdout_fd, 1)
            if not chunk:
                return None
            header += chunk

        length = None
        for line in header.decode("ascii", "replace").split("\r\n"):
            if line.lower().startswith("content-length:"):
                length = int(line.split(":", 1)[1].strip())
                break
        if length is None:
            raise DlsError(f"response without Content-Length header: {bytes(header)!r}")

        body = bytearray()
        while len(body) < length:
            chunk = os.read(self._stdout_fd, length - len(body))
            if not chunk:
                return None
            body += chunk
        return json.loads(body.decode("utf-8"))

    def _dispatch(self, message: dict[str, Any]) -> None:
        with self._condition:
            if "id" in message and ("result" in message or "error" in message):
                self._responses[message["id"]] = message
                self._pending.pop(message["id"], None)
            else:
                self._notifications.append(message)
            self._condition.notify_all()

    def _read_stderr(self) -> None:
        stream = self.process.stderr
        if stream is None:
            return
        while True:
            chunk = stream.readline()
            if not chunk:
                return
            with self._condition:
                self._stderr_lines.append(chunk.decode("utf-8", "replace").rstrip("\n"))
                if len(self._stderr_lines) > STDERR_TAIL_LINES:
                    del self._stderr_lines[: len(self._stderr_lines) - STDERR_TAIL_LINES]
                self._condition.notify_all()

    def send(self, message: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        try:
            self.process.stdin.write(encode_message(message))
            self.process.stdin.flush()
        except (BrokenPipeError, ValueError) as exc:  # pragma: no cover
            raise ServerDied(f"server is gone: {exc}\n{self.stderr_tail()}") from exc

    def notify(self, method: str, params: Any = None) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params if params is not None else {}})

    def request(self, method: str, params: Any = None, *, timeout: float | None = None):
        request_id = next(self._ids)
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        with self._condition:
            self._pending[request_id] = method
        self.send(message)

        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        with self._condition:
            while request_id not in self._responses:
                if self._closed or self.process.poll() is not None:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._condition.wait(remaining)
            response = self._responses.pop(request_id, None)
            self._pending.pop(request_id, None)

        if response is None:
            if self.process.poll() is not None:
                raise ServerDied(
                    f"server exited with code {self.process.returncode} while handling "
                    f"{method!r}\n{self.stderr_tail()}"
                )
            with self._condition:
                reader_error = self._reader_error
            detail = f" (stdout reader stopped: {reader_error})" if reader_error else ""
            raise ResponseTimeout(
                f"no response to {method!r} within the timeout{detail}\n{self.stderr_tail()}"
            )

        if response.get("jsonrpc") != "2.0":
            raise DlsError(f"response is not JSON-RPC 2.0: {response!r}")
        if response.get("id") != request_id:
            raise DlsError(f"response id {response.get('id')!r} != request id {request_id!r}")
        if "error" in response:
            raise RequestError(f"{method!r} failed: {response['error']!r}")
        return response.get("result")

    # -- notifications -----------------------------------------------------

    def wait_for_notification(
        self,
        method: str,
        predicate: Callable[[dict[str, Any]], bool] | None = None,
        *,
        timeout: float | None = None,
        start: int = 0,
    ) -> tuple[int, dict[str, Any]]:
        """Wait for a notification and return ``(index, message)``."""
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        index = start
        with self._condition:
            while True:
                while index < len(self._notifications):
                    candidate = self._notifications[index]
                    if candidate.get("method") == method and (
                        predicate is None or predicate(candidate)
                    ):
                        return index, candidate
                    index += 1
                if self._closed or self.process.poll() is not None:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._condition.wait(remaining)
        raise ResponseTimeout(
            f"no {method!r} notification within the timeout\n{self.stderr_tail()}"
        )

    def notifications(self, method: str | None = None) -> list[dict[str, Any]]:
        with self._condition:
            items = list(self._notifications)
        if method is None:
            return items
        return [item for item in items if item.get("method") == method]

    def wait_for_log_line(
        self,
        predicate: Callable[[str], bool],
        *,
        start: int = 0,
        timeout: float | None = None,
    ) -> bool:
        """Wait (bounded) for a matching server log line; return whether it came.

        ``stderr_lines()`` is filled in by a reader thread, so a test that
        inspects the log right after a notification races it: a request only
        orders the *server's* work, not the reader's.  Wait for a line the
        server writes *after* the ones under test -- lines are appended in the
        order the server wrote them -- and the earlier ones are visible too.
        ``start`` is an index into ``stderr_lines()`` for tests that care only
        about lines written after some point.

        Returns rather than raises, so a caller that also asserts on the log
        keeps its own failure message when the line never shows up.
        """
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        index = max(start, 0)
        with self._condition:
            while True:
                while index < len(self._stderr_lines):
                    if predicate(self._stderr_lines[index]):
                        return True
                    index += 1
                if self._closed or self.process.poll() is not None:
                    return False
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self._condition.wait(remaining)

    def stderr_tail(self) -> str:
        with self._condition:
            lines = list(self._stderr_lines)
        if not lines:
            return "<no server output>"
        return "--- dls stderr (tail) ---\n" + "\n".join(lines[-40:])

    def stderr_lines(self) -> list[str]:
        """Snapshot of the server's captured stderr output."""
        with self._condition:
            return list(self._stderr_lines)

    # -- high level helpers ------------------------------------------------

    def did_open(self, path: str, text: str, *, version: int = 1, language_id: str = "d") -> str:
        uri = path_to_uri(path)
        self.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": uri,
                    "languageId": language_id,
                    "version": version,
                    "text": text,
                }
            },
        )
        return uri

    def did_change(self, uri: str, text: str, *, version: int = 2) -> None:
        self.notify(
            "textDocument/didChange",
            {
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": text}],
            },
        )

    def did_close(self, uri: str) -> None:
        self.notify("textDocument/didClose", {"textDocument": {"uri": uri}})

    def did_save(self, uri: str) -> None:
        self.notify("textDocument/didSave", {"textDocument": {"uri": uri}})

    def _position_params(self, uri: str, line: int, character: int, extra: dict | None = None):
        params: dict[str, Any] = {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
        }
        if extra:
            params.update(extra)
        return params

    def completion(self, uri: str, line: int, character: int) -> dict[str, Any]:
        return self.request(
            "textDocument/completion", self._position_params(uri, line, character)
        )

    def hover(self, uri: str, line: int, character: int) -> dict[str, Any]:
        return self.request("textDocument/hover", self._position_params(uri, line, character))

    def definition(self, uri: str, line: int, character: int) -> list[dict[str, Any]]:
        return self.request("textDocument/definition", self._position_params(uri, line, character))

    def document_symbols(self, uri: str) -> list[dict[str, Any]]:
        return self.request("textDocument/documentSymbol", {"textDocument": {"uri": uri}})

    def signature_help(self, uri: str, line: int, character: int) -> dict[str, Any]:
        return self.request(
            "textDocument/signatureHelp", self._position_params(uri, line, character)
        )

    def semantic_tokens(self, uri: str) -> dict[str, Any]:
        return self.request(
            "textDocument/semanticTokens/full", {"textDocument": {"uri": uri}}
        )

    # -- lifecycle ---------------------------------------------------------

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.request("shutdown", None, timeout=10.0)
                self.notify("exit")
                self.process.wait(timeout=10.0)
            except Exception:
                pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:  # pragma: no cover
                self.process.kill()
                self.process.wait(timeout=5.0)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            try:
                if stream is not None:
                    stream.close()
            except Exception:  # pragma: no cover
                pass


class Doc:
    """A document tracked by the server, with position helpers."""

    def __init__(self, client: LspClient, relpath: str, text: str) -> None:
        self.client = client
        self.relpath = relpath
        self.path = os.path.join(client.root, relpath)
        self.uri = path_to_uri(self.path)
        self.text = text
        self._open = False
        self._version = 0

    @property
    def is_open(self) -> bool:
        return self._open

    def open(self, text: str | None = None, version: int = 1) -> "Doc":
        if text is not None:
            self.text = text
        self.client.did_open(self.path, self.text, version=version)
        self._open = True
        self._version = version
        return self

    def change(self, text: str, version: int | None = None) -> "Doc":
        self.text = text
        self._version = version if version is not None else self._version + 1
        self.client.did_change(self.uri, text, version=self._version)
        return self

    def close(self) -> None:
        if self._open:
            self.client.did_close(self.uri)
            self._open = False

    def position(self, needle: str, offset: int = 0, occurrence: int = 0) -> tuple[int, int]:
        """Return the LSP position ``offset`` characters past ``needle``.

        ``occurrence`` selects a later match when the needle appears more than
        once.  Line/character are UTF-16 code units, which is what the LSP
        uses; the fixtures are pure ASCII so byte counts line up.
        """
        index = -1
        search_from = 0
        for _ in range(occurrence + 1):
            index = self.text.find(needle, search_from)
            if index < 0:
                raise AssertionError(f"fixture {self.relpath!r} does not contain {needle!r}")
            search_from = index + 1
        position = index + len(needle) + offset
        line = self.text.count("\n", 0, position)
        line_start = self.text.rfind("\n", 0, position) + 1
        return line, position - line_start

    # convenience wrappers -------------------------------------------------

    def completion(self, needle: str, offset: int = 0, occurrence: int = 0):
        return self.client.completion(self.uri, *self.position(needle, offset, occurrence))

    def hover(self, needle: str, offset: int = 0, occurrence: int = 0):
        return self.client.hover(self.uri, *self.position(needle, offset, occurrence))

    def definition(self, needle: str, offset: int = 0, occurrence: int = 0):
        return self.client.definition(self.uri, *self.position(needle, offset, occurrence))

    def signature_help(self, needle: str, offset: int = 0, occurrence: int = 0):
        return self.client.signature_help(self.uri, *self.position(needle, offset, occurrence))

    def semantic_tokens(self):
        return self.client.semantic_tokens(self.uri)

    def document_symbols(self):
        return self.client.document_symbols(self.uri)


class DlsTestCase(unittest.TestCase):
    """Base class starting one shared server per test class.

    Subclasses declare their project as ``PROJECT`` (relative path -> text).
    A ``dls.json`` with the project root as an import path is written by
    default: it is the server's only configuration channel, so it is also what
    makes the server register project import paths and watch them.  Set
    ``WRITE_DLS_JSON`` to ``False`` to pin what a workspace without one gets
    (the compiler's default paths and nothing else), or set ``CHECK`` to a list
    of ``{"path": ..., "cmd": ...}`` entries to test diagnostics.
    """

    PROJECT: dict[str, str] = {"app.d": "module app;\n"}
    WRITE_DLS_JSON: bool = True
    CHECK: list[dict[str, str]] | None = None
    IMPORT_PATHS: list[str] | None = None
    #: Import paths expressed relative to the test's project root (resolved in
    #: ``setUpClass``, so a test can keep the project root out of them - which
    #: is what tells "watch the import paths" apart from "watch everything").
    #: Takes precedence over ``IMPORT_PATHS`` and is written to ``dls.json``.
    IMPORT_PATHS_RELATIVE: list[str] | None = None
    #: ClientCapabilities sent with 'initialize'.  The empty default matches a
    #: client that supports nothing special (so a test never accidentally
    #: exercises a capability-dependent server path); a test that needs one
    #: declares it here.
    CLIENT_CAPABILITIES: dict[str, Any] = {}

    client: LspClient
    root: str
    docs: dict[str, Doc]

    @classmethod
    def setUpClass(cls) -> None:
        cls.root = tempfile.mkdtemp(prefix="dls-tests-")

        for relpath, text in cls.PROJECT.items():
            path = os.path.join(cls.root, relpath)
            write_text(path, text)

        if cls.IMPORT_PATHS_RELATIVE is not None:
            import_paths = [os.path.join(cls.root, p) for p in cls.IMPORT_PATHS_RELATIVE]
        else:
            import_paths = cls.IMPORT_PATHS or [cls.root]

        if cls.WRITE_DLS_JSON:
            config: dict[str, Any] = {"importPaths": import_paths}
            if cls.CHECK:
                config["check"] = cls.CHECK
            with open(os.path.join(cls.root, "dls.json"), "w", encoding="utf-8") as handle:
                json.dump(config, handle)

        cls.import_paths = import_paths
        try:
            cls.client = LspClient(
                find_server(),
                cls.root,
                client_capabilities=cls.CLIENT_CAPABILITIES,
            )
        except Exception:
            shutil.rmtree(cls.root, ignore_errors=True)
            raise
        cls.docs = {
            relpath: Doc(cls.client, relpath, text)
            for relpath, text in cls.PROJECT.items()
        }

    @classmethod
    def _restart_client(cls) -> None:
        """Start a fresh server after one died (tests that crash the server)."""
        try:
            cls.client.close()
        except Exception:
            pass
        cls.client = LspClient(
            find_server(),
            cls.root,
            client_capabilities=cls.CLIENT_CAPABILITIES,
        )
        for doc in cls.docs.values():
            doc.client = cls.client
            doc._open = False

    def setUp(self) -> None:
        # A test that kills the server should not cascade into every following
        # test in the class: bring a new one up and keep going.
        if self.client.process.poll() is not None:
            self._restart_client()

    @classmethod
    def tearDownClass(cls) -> None:
        try:
            cls.client.close()
        finally:
            shutil.rmtree(cls.root, ignore_errors=True)

    # helpers --------------------------------------------------------------

    def doc(self, relpath: str = "app.d") -> Doc:
        """Return the fixture document for ``relpath``."""
        return self.docs[relpath]

    def open_doc(self, relpath: str = "app.d", text: str | None = None) -> Doc:
        """Open a fixture document (and register it in ``tearDown``)."""
        doc = self.doc(relpath)
        doc.open(text)
        self.addCleanup(doc.close)
        return doc

    def write_file(self, relpath: str, text: str) -> Doc:
        """Add a document to the project after the server started."""
        path = os.path.join(self.root, relpath)
        write_text(path, text)
        doc = Doc(self.client, relpath, text)
        self.docs[relpath] = doc
        return doc
