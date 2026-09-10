"""Hermetic bootstrap/identity tests; never download or execute Codecov."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse
import urllib.error


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "upload_codecov", Path(__file__).parents[1] / "files" / "upload-codecov.py"
)
UPLOADER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPLOADER)
BINARY = b"inert uploader fixture; subprocess is stubbed\n"
COMMIT = "a" * 40
PR_COMMIT = "b" * 40


class CodecovUploadTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codecov-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        prior = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, prior)
        self.event = {
            "repository": {"full_name": "example/product"},
            "after": COMMIT,
            "ref": "refs/heads/main",
        }
        self.env = {
            "GITHUB_EVENT_PATH": str(self.root / "event.json"),
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REPOSITORY": "example/product",
            "GITHUB_RUN_ID": "1234",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": COMMIT,
            "GITHUB_WORKSPACE": str(self.root),
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://pipelines.actions.githubusercontent.com/idtoken?api-version=1.0",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "fixture-request-token",
            "CODECOV_TOKEN": "unrelated-static-token",
            "UNRELATED_SECRET": "must-not-reach-child",
            "PATH": "/usr/bin:/bin",
        }
        (self.root / "lcov.info").write_text("TN:\nSF:src/example.rs\nDA:1,1\nend_of_record\n")
        (self.root / "junit.xml").write_text('<testsuite tests="1"/>\n')
        self.requests = []
        self.invocations = []

    def network(self, request):
        self.requests.append(request)
        if isinstance(request, str):
            self.assertEqual(request, UPLOADER.CLI_URL)
            return io.BytesIO(BINARY)
        self.assertEqual(request.get_header("Authorization"), "Bearer fixture-request-token")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)
        self.assertEqual(query["audience"], ["https://codecov.io"])
        return io.BytesIO(b'{"value":"fixture-oidc-token"}')

    def command(self, argv, *, env, cwd, check):
        self.assertFalse(check)
        self.assertEqual(Path(argv[0]).read_bytes(), BINARY)
        self.assertTrue(os.access(argv[0], os.X_OK))
        self.assertEqual((cwd / "codecov.yml").read_text(), "{}\n")
        self.assertEqual(list((cwd / "network").iterdir()), [])
        self.assertNotEqual(cwd, self.root)
        self.assertEqual(env["CODECOV_TOKEN"], "fixture-oidc-token")
        self.assertNotIn("ACTIONS_ID_TOKEN_REQUEST_TOKEN", env)
        self.assertNotIn("UNRELATED_SECRET", env)
        self.invocations.append(argv)
        return subprocess.CompletedProcess(argv, 0)

    def run_upload(self, *arguments, network=None, command=None, expected_hash=None, coverage=True):
        Path(self.env["GITHUB_EVENT_PATH"]).write_text(json.dumps(self.event))
        output = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(UPLOADER, "CLI_SHA256", expected_hash or hashlib.sha256(BINARY).hexdigest()), \
                patch.object(UPLOADER, "open_https", side_effect=network or self.network), \
                patch.object(UPLOADER.subprocess, "run", side_effect=command or self.command), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            defaults = ["--coverage", "lcov.info"] if coverage else []
            result = UPLOADER.main([*defaults, *arguments])
        return result, output.getvalue()

    def test_push_uploads_explicit_coverage_and_junit_with_isolated_token(self):
        result, output = self.run_upload("--junit", "junit.xml")
        self.assertEqual(result, 0, output)
        self.assertEqual(len(self.invocations), 2)
        for command, report_type, filename in zip(
                self.invocations, ["coverage", "test_results"], ["lcov.info", "junit.xml"]):
            self.assertIn("--fail-on-error", command)
            self.assertIn("--disable-search", command)
            self.assertIn("--disable-file-fixes", command)
            self.assertEqual(command[command.index("--plugin") + 1], "noop")
            self.assertEqual(command[command.index("--commit-sha") + 1], COMMIT)
            self.assertEqual(command[command.index("--build-code") + 1], "1234")
            self.assertEqual(command[command.index("--build-url") + 1],
                             "https://github.com/example/product/actions/runs/1234")
            self.assertEqual(command[command.index("--report-type") + 1], report_type)
            self.assertEqual(command[command.index("--file") + 1], str(self.root / filename))
            self.assertNotIn("--token", command)
            self.assertNotIn("--pr", command)
        self.assertIn("::add-mask::fixture-oidc-token", output)

    def use_pr(self):
        self.env.update(GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/19/merge")
        self.event["number"] = 19
        self.event["pull_request"] = {
            "head": {"sha": PR_COMMIT, "ref": "dependabot/cargo/example-2", "repo": {"full_name": "example/product"}}
        }

    def test_same_repository_dependabot_uses_pr_head_not_merge_sha(self):
        self.use_pr()
        self.env["GITHUB_ACTOR"] = "dependabot[bot]"
        result, output = self.run_upload()
        self.assertEqual(result, 0, output)
        command = self.invocations[0]
        self.assertEqual(command[command.index("--commit-sha") + 1], PR_COMMIT)
        self.assertEqual(command[command.index("--pr") + 1], "19")
        self.assertEqual(command[command.index("--branch") + 1], "dependabot/cargo/example-2")

    def test_rejects_missing_oidc_without_static_token_fallback(self):
        for missing in ["ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL"]:
            with self.subTest(missing=missing):
                previous = self.env.pop(missing)
                result, output = self.run_upload()
                self.assertEqual(result, 1, output)
                self.assertEqual(self.requests, [])
                self.env[missing] = previous

    def test_rejects_hash_mismatch_before_oidc_or_execution(self):
        result, output = self.run_upload(expected_hash="0" * 64)
        self.assertEqual(result, 1, output)
        self.assertEqual(self.requests, [UPLOADER.CLI_URL])
        self.assertEqual(self.invocations, [])

    def test_rejects_missing_and_empty_artifacts_before_network(self):
        for path in ["absent.xml", "empty.xml"]:
            (self.root / "empty.xml").touch()
            result, output = self.run_upload("--junit", path)
            self.assertEqual(result, 1, output)
            self.assertEqual(self.requests, [])

    def test_rejects_symlink_and_outside_report_paths(self):
        (self.root / "linked.xml").symlink_to(self.root / "junit.xml")
        for path in ["linked.xml", "../report.xml", str(self.root / "junit.xml")]:
            result, output = self.run_upload("--junit", path)
            self.assertEqual(result, 1, output)
            self.assertEqual(self.requests, [])

    def test_upload_failure_blocks_later_reports(self):
        def failed(*args, **kwargs):
            self.command(*args, **kwargs)
            return subprocess.CompletedProcess(args[0], 7)
        result, output = self.run_upload("--junit", "junit.xml", command=failed)
        self.assertEqual(result, 1, output)
        self.assertEqual(len(self.invocations), 1)

    def test_junit_upload_failure_fails_even_after_coverage_succeeds(self):
        def failed_junit(*args, **kwargs):
            self.command(*args, **kwargs)
            return subprocess.CompletedProcess(args[0], 8 if "test_results" in args[0] else 0)
        result, output = self.run_upload("--junit", "junit.xml", command=failed_junit)
        self.assertEqual(result, 1, output)
        self.assertEqual(len(self.invocations), 2)

    def test_rejects_fork_or_target_context_before_network(self):
        self.use_pr()
        self.event["pull_request"]["head"]["repo"]["full_name"] = "other/product"
        result, output = self.run_upload()
        self.assertEqual(result, 1, output)
        self.env["GITHUB_EVENT_NAME"] = "pull_request_target"
        result, output = self.run_upload()
        self.assertEqual(result, 1, output)
        self.assertEqual(self.requests, [])

    def test_rejects_mismatched_push_and_pr_identity(self):
        self.event["after"] = PR_COMMIT
        result, output = self.run_upload()
        self.assertEqual(result, 1, output)
        self.use_pr()
        self.env["GITHUB_REF"] = "refs/pull/20/merge"
        result, output = self.run_upload()
        self.assertEqual(result, 1, output)
        self.assertEqual(self.requests, [])

    def test_rejects_non_github_oidc_endpoint_before_network(self):
        self.env["ACTIONS_ID_TOKEN_REQUEST_URL"] = "https://example.invalid/idtoken"
        result, output = self.run_upload()
        self.assertEqual(result, 1, output)
        self.assertEqual(self.requests, [])

    def test_rejects_empty_oidc_response_without_execution(self):
        def empty(request):
            return self.network(request) if isinstance(request, str) else io.BytesIO(b'{"value":""}')
        result, output = self.run_upload(network=empty)
        self.assertEqual(result, 1, output)
        self.assertEqual(self.invocations, [])

    def test_oidc_network_failure_is_redacted_and_prevents_execution(self):
        def failure(request):
            if isinstance(request, str):
                return self.network(request)
            raise urllib.error.URLError("fixture-private-query-value")
        result, output = self.run_upload(network=failure)
        self.assertEqual(result, 1, output)
        self.assertNotIn("fixture-private-query-value", output)
        self.assertEqual(self.invocations, [])

    def test_oidc_redirect_is_rejected_without_forwarding_credentials(self):
        handler = UPLOADER.NoRedirect()
        with self.assertRaises(UPLOADER.UploadError):
            handler.redirect_request(None, None, 302, "Found", {}, "https://example.invalid")

    def test_prepare_normalizes_lcov_without_oidc_or_network_and_preserves_junit(self):
        del self.env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
        (self.root / "lcov.info").write_text(f"TN:\nSF:{self.root}/Sources/App.swift\nDA:1,1\nend_of_record\n")
        before_junit = (self.root / "junit.xml").read_bytes()
        result, output = self.run_upload("--prepare", "--junit", "junit.xml")
        self.assertEqual(result, 0, output)
        self.assertEqual((self.root / "lcov.info").read_text(),
                         "TN:\nSF:Sources/App.swift\nDA:1,1\nend_of_record\n")
        self.assertEqual((self.root / "junit.xml").read_bytes(), before_junit)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.invocations, [])

    def test_prepare_normalizes_cobertura_source_and_nested_filenames(self):
        (self.root / "coverage.xml").write_text(
            f'<coverage><sources><source>{self.root}/engine</source></sources>'
            '<packages><package name="app"><classes><class filename="lib/app.rb"/>'
            '</classes></package></packages></coverage>'
        )
        result, output = self.run_upload("--prepare", "--coverage", "coverage.xml")
        self.assertEqual(result, 0, output)
        normalized = UPLOADER.ET.fromstring((self.root / "coverage.xml").read_text())
        self.assertEqual(normalized.find("./sources/source").text, ".")
        self.assertEqual(normalized.find(".//class").get("filename"), "engine/lib/app.rb")
        self.assertEqual(self.requests, [])

    def test_prepare_rejects_outside_paths_without_partial_report_changes(self):
        initial = f"TN:\nSF:{self.root}/src/main.rs\nDA:1,1\nend_of_record\n"
        (self.root / "lcov.info").write_text(initial)
        for source in ["/unexpected/source.rs", "../outside.rs", f"{self.root}-other/src/main.rs"]:
            (self.root / "second.info").write_text(f"SF:{source}\nDA:1,1\nend_of_record\n")
            result, output = self.run_upload("--prepare", "--coverage", "second.info")
            self.assertEqual(result, 1, output)
            self.assertEqual((self.root / "lcov.info").read_text(), initial)
        self.assertEqual(self.requests, [])

    def test_prepare_is_idempotent_for_relative_lcov_and_cobertura(self):
        (self.root / "coverage.xml").write_text(
            '<coverage><sources><source>.</source></sources><packages><package><classes>'
            '<class filename="lib/app.rb"/></classes></package></packages></coverage>'
        )
        result, output = self.run_upload("--prepare", "--coverage", "coverage.xml")
        self.assertEqual(result, 0, output)
        first = [(self.root / path).read_bytes() for path in ["lcov.info", "coverage.xml"]]
        result, output = self.run_upload("--prepare", "--coverage", "coverage.xml")
        self.assertEqual(result, 0, output)
        self.assertEqual([(self.root / path).read_bytes() for path in ["lcov.info", "coverage.xml"]], first)

    def test_upload_rejects_unprepared_report_paths_before_oidc_or_network(self):
        (self.root / "lcov.info").write_text("SF:/Users/runner/work/example/src/app.swift\nDA:1,1\nend_of_record\n")
        result, output = self.run_upload()
        self.assertEqual(result, 1, output)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.invocations, [])

    def test_junit_only_upload_preserves_failed_test_report(self):
        (self.root / "lcov.info").unlink()
        result, output = self.run_upload("--junit", "junit.xml", coverage=False)
        self.assertEqual(result, 0, output)
        self.assertEqual(len(self.invocations), 1)
        command = self.invocations[0]
        self.assertEqual(command[command.index("--report-type") + 1], "test_results")
        self.assertIn("--fail-on-error", command)

    def test_junit_only_failure_propagates(self):
        def failed(*args, **kwargs):
            self.command(*args, **kwargs)
            return subprocess.CompletedProcess(args[0], 7)
        result, output = self.run_upload("--junit", "junit.xml", coverage=False, command=failed)
        self.assertEqual(result, 1, output)
        self.assertEqual(len(self.invocations), 1)

    def test_junit_only_prepare_preserves_bytes_without_oidc_or_network(self):
        del self.env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
        (self.root / "lcov.info").unlink()
        original = (self.root / "junit.xml").read_bytes()
        result, output = self.run_upload("--prepare", "--junit", "junit.xml", coverage=False)
        self.assertEqual(result, 0, output)
        self.assertEqual((self.root / "junit.xml").read_bytes(), original)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.invocations, [])

    def test_junit_only_still_requires_oidc_and_report_file(self):
        previous = self.env.pop("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
        result, output = self.run_upload("--junit", "junit.xml", coverage=False)
        self.assertEqual(result, 1, output)
        self.env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = previous
        result, output = self.run_upload("--junit", "absent.xml", coverage=False)
        self.assertEqual(result, 1, output)
        self.assertEqual(self.requests, [])

    def test_no_report_arguments_are_rejected(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_upload(coverage=False)
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.invocations, [])


if __name__ == "__main__":
    unittest.main()
