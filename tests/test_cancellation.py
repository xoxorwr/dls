"""Requests the client no longer needs, and the framing that lets the server see that.

The server looks at what the client has already sent before it answers a
request: a ``$/cancelRequest`` for it means it is skipped (``RequestCancelled``),
and a semantic token request whose document a queued ``didChange`` replaces is
answered with ``ContentModified`` - a client asks again after that, and keeps
the tokens it shows until then.

``send_batch`` writes several messages at once, which is what puts a cancel or
a change *behind* a request deterministically.
"""

import time

from harness import DlsTestCase, encode_message

REQUEST_CANCELLED = -32800
CONTENT_MODIFIED = -32801

APP = """module app;

struct Point
{
    int x;
}

void main()
{
    Point p;
    p.x = 1;
}
"""

OTHER = """module other;

void helper() {}
"""


class CancellationTests(DlsTestCase):
    PROJECT = {
        "app.d": APP,
        "other.d": OTHER,
    }

    def _request(self, method, params):
        request_id = self.client.next_request_id()
        return request_id, {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}

    def _tokens_request(self, doc):
        return self._request("textDocument/semanticTokens/full", {"textDocument": {"uri": doc.uri}})

    def _change(self, doc, text, version):
        doc.text = text
        return {
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": {
                "textDocument": {"uri": doc.uri, "version": version},
                "contentChanges": [{"text": text}],
            },
        }

    @staticmethod
    def _cancel(request_id):
        return {"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": request_id}}

    # -- $/cancelRequest ---------------------------------------------------

    def test_a_request_cancelled_before_it_ran_is_answered_with_request_cancelled(self):
        doc = self.open_doc("app.d")
        line, character = doc.position("p.x", -1)
        request_id, request = self._request(
            "textDocument/hover",
            {"textDocument": {"uri": doc.uri}, "position": {"line": line, "character": character}},
        )

        self.client.send_batch([request, self._cancel(request_id)])

        response = self.client.wait_for_response(request_id)
        self.assertEqual(response["error"]["code"], REQUEST_CANCELLED)
        self.assertNotIn("result", response)

    def test_a_cancel_for_another_request_does_not_cancel_this_one(self):
        doc = self.open_doc("app.d")
        request_id, request = self._tokens_request(doc)

        self.client.send_batch([request, self._cancel(request_id + 1000)])

        response = self.client.wait_for_response(request_id)
        self.assertIn("result", response)
        self.assertTrue(response["result"]["data"])

    def test_a_cancel_for_an_answered_request_is_ignored_quietly(self):
        doc = self.open_doc("app.d")
        request_id, request = self._tokens_request(doc)
        self.client.send(request)
        self.client.wait_for_response(request_id)

        self.client.send(self._cancel(request_id))
        # Still serving, and the cancel is not reported as an unknown method.
        self.assertTrue(doc.semantic_tokens()["data"])
        unhandled = [line for line in self.client.stderr_lines()
                     if "$/cancelRequest" in line and "not handled" in line]
        self.assertEqual(unhandled, [])

    # -- semantic tokens superseded by a queued change ----------------------

    def test_tokens_for_a_document_a_queued_change_replaces_are_content_modified(self):
        doc = self.open_doc("app.d")
        request_id, request = self._tokens_request(doc)
        changed = APP.replace("Point p;", "Point q;").replace("p.x", "q.x")

        self.client.send_batch([request, self._change(doc, changed, 2)])

        response = self.client.wait_for_response(request_id)
        self.assertEqual(response["error"]["code"], CONTENT_MODIFIED)
        # The client asks again, and gets the tokens of the new text.
        self.assertTrue(doc.semantic_tokens()["data"])
        doc.change(APP)

    def test_a_queued_change_to_another_document_does_not_matter(self):
        doc = self.open_doc("app.d")
        other = self.open_doc("other.d")
        request_id, request = self._tokens_request(doc)

        self.client.send_batch([request, self._change(other, OTHER + "\n", 2)])

        self.assertIn("result", self.client.wait_for_response(request_id))

    def test_tokens_already_computed_are_answered_even_with_a_change_queued(self):
        # They are about the text the request was made for, and cost nothing.
        doc = self.open_doc("app.d")
        expected = doc.semantic_tokens()["data"]
        request_id, request = self._tokens_request(doc)

        self.client.send_batch([request, self._change(doc, APP + "\n", 2)])

        self.assertEqual(self.client.wait_for_response(request_id)["result"]["data"], expected)
        doc.change(APP)

    # -- framing -----------------------------------------------------------

    def test_a_message_split_across_writes_is_read_whole(self):
        doc = self.open_doc("app.d")
        request_id, request = self._tokens_request(doc)
        data = encode_message(request)

        # Mid-header, then mid-body.
        for part in (data[:7], data[7:30], data[30:]):
            self.client.process.stdin.write(part)
            self.client.process.stdin.flush()
            time.sleep(0.05)

        self.assertTrue(self.client.wait_for_response(request_id)["result"]["data"])

    def test_a_message_larger_than_a_read_is_read_whole(self):
        # Several times the server's read size: the buffer has to grow.
        filler = "".join(f"int value{i} = {i};\n" for i in range(20000))
        text = APP + filler
        self.assertGreater(len(text), 4 * 64 * 1024)
        doc = self.open_doc("app.d", text)

        tokens = doc.semantic_tokens()["data"]
        self.assertGreater(len(tokens) // 5, 20000)
        doc.change(APP)
