# Simulator validation

The [offline workflow](../.github/workflows/helpers.yml) runs pairing compatibility and test-helper checks on GitHub-hosted Ubuntu for pushes to `main`, pull requests and manual dispatch. It needs no model keys, device or dedicated runner.

The [Apple workflow](../.github/workflows/checks.yml) runs on pushes to `main` and manual dispatch only when the repository variable `EISCUE_APPLE_RUNNERS_ENABLED` is `true`. It requires two registered **self-hosted Apple Silicon macOS runners**. Leave the variable unset until they are ready, so jobs do not queue indefinitely. Adding a workflow does not provision runners or enable branch protection.

| Runner label | Repository variable | Installed simulator runtime |
| --- | --- | --- |
| `eiscue-xcode26` | `EISCUE_XCODE26_DEVELOPER_DIR` | iOS 26.3.x |
| `eiscue-xcode27` | `EISCUE_XCODE27_DEVELOPER_DIR` | iOS 27.0.x |

Each variable names that runner's Xcode `Contents/Developer` directory. Install XcodeGen 2.45+, Python 3, and the listed runtime first. Use separate runner machines or isolated macOS accounts; the jobs create and delete only their own simulators. No physical devices or model credentials are used. Untrusted pull requests do not run on these self-hosted machines.

Once both runners report online, set `EISCUE_APPLE_RUNNERS_ENABLED=true`, dispatch the Apple workflow and inspect both jobs' actual results before requiring them in branch protection. The offline helper job alone does not check Swift, UIKit or device control.

Run the same gate locally with an explicit toolchain and a new output directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 Scripts/run-ci-checks.py --xcode-major 26 --ios-version 26.3 \
  --output .build/ci-local-xcode26
```

The gate checks helper tests, all Kit tests, generated-project drift, full and HID Release simulator builds, the HID linkage/entitlement boundary, HID app tests, the complete iPhone App/UI suite, and iPad sidebar/conversation/sharing UI cases. It rejects a missing or mismatched toolchain/runtime before testing. Hardware-only and opposite-OS cases remain explicit skips.

`run-logged-check.sh` records and returns the child command's actual exit code. `run-with-model-fixture.py` owns one loopback model fixture, waits for readiness, and records intentional shutdown separately; an externally running fixture is never killed. Test failures remain nonzero even after fixture cleanup. `test-swift-package.py` copies the manifest and lockfile into a temporary package with symlinked sources and an explicit scratch directory: it never rewrites or restores the real `Package.resolved` or Git index, and rejects concurrent changes to either state.

Workflow artifacts retain logs and result bundles on success or failure. Local and simulator checks do not establish BLE/USB input, ReplayKit, cross-app control, or background-duration acceptance. The generic device HID build was also checked locally without signing; actual provisioning, signature entitlements and hardware behavior remain separate checks.
