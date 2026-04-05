# OWASP Dependency-Check Setup

Chronicle uses the [OWASP Dependency-Check](https://owasp.org/www-project-dependency-check/) Gradle plugin (`org.owasp.dependencycheck`) to scan for known vulnerabilities (CVEs) in third-party dependencies. The plugin is declared in `settings.gradle.kts` under `pluginManagement`.

## Prerequisites: NVD API Key

The NVD (National Vulnerability Database) rate-limits anonymous requests. An API key is required for reliable scans.

1. Visit https://nvd.nist.gov/developers/request-an-api-key
2. Fill in the registration form (name + email).
3. Confirm the email. You will receive your API key.

## Setting the API Key

Export the key as an environment variable before running the check:

```bash
export NVD_API_KEY="your-api-key-here"
```

For persistent configuration, add it to your shell profile (`~/.bashrc`, `~/.zshrc`) or a `.env` file that is **not committed to version control**.

The Gradle plugin reads the key via the `nvdApiKey` property. Pass it on the command line or in `gradle.properties`:

```bash
# Command-line
./gradlew dependencyCheckAnalyze -PnvdApiKey="$NVD_API_KEY"

# Or in ~/.gradle/gradle.properties (user-level, not committed)
nvdApiKey=your-api-key-here
```

## Running Locally

Apply the plugin in the module you want to scan (or the root project) and run:

```bash
# Scan all subprojects
./gradlew dependencyCheckAnalyze -PdevelopmentMode=true

# Scan a single module
./gradlew :chronicle-server:dependencyCheckAnalyze -PdevelopmentMode=true
```

The HTML report is generated at `build/reports/dependency-check-report.html`.

### Common Options

| Flag | Purpose |
|------|---------|
| `--info` | Verbose logging (useful for first-run NVD download) |
| `-PnvdApiKey=KEY` | Pass NVD API key |
| `-PdependencyCheck.failBuildOnCVSS=7` | Fail build on CVSS >= 7 |

The first run downloads the full NVD database (~2 GB) and may take 10-20 minutes. Subsequent runs use a cached/incremental update.

## Adding to CI

Add a GitHub Actions step (or equivalent) after the build:

```yaml
- name: OWASP Dependency Check
  env:
    NVD_API_KEY: ${{ secrets.NVD_API_KEY }}
  run: |
    ./gradlew dependencyCheckAnalyze \
      -PnvdApiKey="$NVD_API_KEY" \
      -PdependencyCheck.failBuildOnCVSS=7

- name: Upload Dependency-Check Report
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: dependency-check-report
    path: '**/build/reports/dependency-check-report.html'
```

Store `NVD_API_KEY` as a GitHub Actions secret (Settings > Secrets and variables > Actions).

### CI Tips

- Cache the NVD database between runs (`~/.gradle/dependency-check-data/`) to avoid re-downloading.
- Set `failBuildOnCVSS` to enforce a vulnerability threshold (7 = High, 9 = Critical).
- Run the check on a schedule (e.g., weekly cron) in addition to PR checks, since new CVEs are published daily.
