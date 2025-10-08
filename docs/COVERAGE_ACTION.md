# Coverage Comment Action

This GitHub Action analyzes code coverage from an lcov.info file and automatically comments on pull requests with per-file coverage details when the overall coverage is below a specified threshold.

## Features

- 📊 Parses lcov.info files to extract coverage data
- 📈 Calculates overall and per-file coverage percentages
- 💬 Automatically comments on PRs when coverage is below threshold
- 🎯 Only comments when overall coverage is below the specified threshold (default: 80%)
- 🗂️ Shows per-file coverage breakdown in a readable table format
- 🔄 Uses sticky comments that update/remove automatically

## Usage

### Basic Usage

```yaml
- name: Comment Coverage Analysis
  uses: ./.github/workflows/coverage-comment.yml
  with:
    coverage_file: coverage/lcov.info
    min_coverage_threshold: 80
```

### Advanced Usage

```yaml
- name: Comment Coverage Analysis
  uses: ./.github/workflows/coverage-comment.yml
  with:
    coverage_file: "custom/path/to/coverage.info"
    min_coverage_threshold: 85
    comment_header: "custom-coverage-analysis"
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `coverage_file` | Path to the lcov.info coverage file | No | `coverage/lcov.info` |
| `min_coverage_threshold` | Minimum coverage percentage threshold | No | `80` |
| `comment_header` | Header used for the sticky PR comment | No | `coverage-analysis` |

## Output

The action will:

1. **Parse the lcov.info file** to extract coverage data for each file
2. **Calculate overall coverage** percentage across all files
3. **Generate a detailed comment** with:
   - Overall coverage percentage with status indicator
   - Per-file coverage breakdown in a table
   - Color-coded status indicators (🟢 80%+, 🟡 50-79%, 🔴 <50%)
4. **Comment on the PR** only if overall coverage is below the threshold
5. **Remove previous comments** if coverage improves above the threshold

## Example Output

When coverage is below the threshold, the action will post a comment like:

```markdown
## 📊 Code Coverage Analysis

**Overall Coverage: 75.2%** ❌

The overall coverage is below the 80% threshold.

### Per-File Coverage Details

| File | Coverage | Lines Hit/Total |
|------|----------|-----------------|
| `lib/src/utils.dart` | 45.5% 🔴 | 15/33 |
| `lib/src/parser.dart` | 67.8% 🟡 | 45/66 |
| `lib/src/validator.dart` | 89.2% 🟢 | 58/65 |

### Coverage Legend
- 🟢 80%+ coverage
- 🟡 50-79% coverage  
- 🔴 <50% coverage

**Note:** This analysis is based on line coverage from the lcov.info file.
```

## Integration with Existing Workflows

This action is designed to work alongside existing coverage reporting tools. It's already integrated into the main CI workflow and will run automatically on pull requests.

## Requirements

- The coverage file must be in lcov.info format
- The workflow must have `pull-requests: write` permission
- Python 3 must be available in the runner environment (default on ubuntu-latest)

## Error Handling

- If the coverage file doesn't exist, the action will skip execution
- If the coverage file is malformed, the action will fail with an error message
- The action uses `continue-on-error: true` in the CI workflow to prevent blocking other steps
