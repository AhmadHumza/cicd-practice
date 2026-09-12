# CI/CD Learning Summary — dbt + DuckDB + Git Setup

A record of what you've actually built and debugged so far, with the reasoning behind each piece. This is the raw material for talking about this project in an interview — the failures are as valuable as the successes.

---

## 1. Why the environment setup mattered (and what went wrong)

**The core problem:** your Python was version 3.8 (past end-of-life) and, on your Apple Silicon Mac, was an Intel (`x86_64`) build running under Rosetta emulation rather than a native `arm64` build. This meant `pip` couldn't find a prebuilt "wheel" (precompiled package) for `duckdb` matching your setup, so it tried to compile it from source — which failed because the required C++ build tooling wasn't set up correctly.

**The fix, and why each step existed:**

| Command | What it does | Why it was needed |
|---|---|---|
| `python -c "import platform; print(platform.machine())"` | Prints your Python's actual CPU architecture | Diagnostic — confirmed you were on `x86_64` under Rosetta, not native `arm64` |
| `brew install pyenv` | Installs pyenv, a tool for managing multiple Python versions on one machine | You needed a newer Python without breaking whatever else on your system depends on the old one |
| `pyenv install 3.11.9` | Compiles and installs Python 3.11.9 locally via pyenv | Gets you a modern, natively-built `arm64` Python |
| `pyenv local 3.11.9` | Sets which Python version applies *inside this specific folder* | Scopes the version to your project without changing your global default |
| `pyenv which python` | Shows the full path of the Python pyenv is currently pointing at | Verification step — confirms pyenv is actually active before trusting anything built on top of it |
| `$(pyenv which python) -m venv venv` | Creates a virtual environment using that *specific* interpreter, not whatever `python` happens to resolve to | Avoids the exact bug you hit earlier, where a venv silently used the old 3.8 interpreter |

**Key lesson:** "it says command succeeded" isn't the same as "it did what I think it did." Several steps *looked* fine (a wheel got built, a folder got created) while quietly running against the wrong Python version or in the wrong directory. The habit of checking `python --version`, `which dbt`, and folder contents after each step — rather than trusting the absence of a red error message — is the actual skill here, and it transfers directly to debugging CI pipelines later.

**Two harmless build warnings you can ignore/understand:**
- `lzma` extension missing → fixed with `brew install xz` then rebuilding Python. Only matters if a package later needs compression support.
- `tkinter` extension missing → irrelevant. It's a GUI toolkit; nothing in this stack touches it.

---

## 2. Virtual environments

```bash
python -m venv venv        # create an isolated environment
source venv/bin/activate   # activate it (your prompt shows "(venv)" when active)
deactivate                 # exit it
```

**Reasoning:** a venv keeps this project's Python packages (dbt, duckdb, etc.) separate from your system Python and from other projects. Without it, installing one project's dependencies can silently break another's.

**Pitfall you hit:** activating a venv doesn't mean it was built correctly. `(venv)` in your prompt just means *a* virtual environment is active — it doesn't confirm which Python version it was built from. Always confirm with `python --version` inside it.

---

## 3. dbt commands

```bash
dbt init my_ecommerce_project   # scaffolds a new dbt project (folders + config)
dbt seed                        # loads CSV files from seeds/ into the database as tables
dbt run                         # builds your models (the .sql files in models/)
dbt test                        # runs data quality tests defined in schema.yml files
dbt --version                   # confirms dbt core + adapter (duckdb) versions installed
```

**Reasoning for the seed → run → test order:**
- `seed` gets raw data in
- `run` transforms it (your `stg_orders.sql` selects and renames columns from the raw seed)
- `test` checks the output meets basic guarantees (e.g. no duplicate or null `order_id`)

This exact sequence — `dbt seed && dbt run && dbt test` — is what your GitHub Actions workflow will eventually automate on every pull request. Everything you did manually today is the thing CI exists to do for you automatically.

**Example model** (`models/staging/stg_orders.sql`):
```sql
select
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp as order_purchase_at,
    order_delivered_customer_date as delivered_at
from {{ ref('raw_orders') }}
```
`{{ ref('raw_orders') }}` is dbt's way of referencing another table/model by name rather than hardcoding a schema — this is what lets dbt understand dependencies and build things in the right order.

**Example test** (`models/staging/schema.yml`):
```yaml
version: 2

models:
  - name: stg_orders
    columns:
      - name: order_id
        tests:
          - unique
          - not_null
```
This declares two checks on `order_id`: no duplicates, no nulls. `dbt test` runs these and fails loudly if either check doesn't hold — this is your first real "quality gate," the same concept a CI pipeline enforces before letting code merge.

**A failure worth understanding, not just fixing:** your first `dbt test` run showed one failure — `not_null_my_first_dbt_model_id`. This wasn't a bug in your work; it was the leftover placeholder model dbt scaffolds by default (`models/example/`), which has bad test data on purpose as a demo. The two tests on *your* model (`stg_orders`) both passed. Reading the error output carefully — noticing which file path the failure pointed to — is what told you it wasn't your problem, rather than panicking and assuming your pipeline was broken.

---

## 4. DuckDB

```bash
duckdb dev.duckdb          # opens an interactive SQL shell against your local database file
```
Inside the shell:
```sql
SELECT * FROM raw_orders LIMIT 5;   -- ordinary SQL, needs a semicolon
.tables                              -- CLI meta-command (dot prefix, no semicolon) — lists tables
.exit                                -- leave the shell
```

**Why DuckDB specifically:** it's a serverless, file-based database — `dev.duckdb` is just a file sitting in your project folder, with no server to run, no credentials to manage, no account to sign up for. This let you prove the entire pipeline shape (seed → model → test) works before adding the complexity of a real cloud warehouse's authentication.

---

## 5. Filesystem / shell lessons (the unglamorous but genuinely important part)

- **Always confirm your working directory before running a command that moves or deletes files.** `pwd` and `ls` are cheap; a wrong `mv` or `rm -rf` in the wrong folder isn't.
- **Quote paths with spaces.** `cd "/Users/you/Documents/Git Repo/project"` — without quotes, the shell treats `Git` and `Repo` as two separate words, which caused the stuck `quote>` prompt earlier.
- **`rmdir` only removes empty folders** — it failing with "Directory not empty" is a safety feature, not a bug. Use `ls -a` to see what's actually still in there (hidden files count) before deciding whether to `rm -rf`.
- **Don't move a venv folder after creating it.** Installed tools like `dbt` have absolute paths baked into them at install time; moving the folder can silently break them. Delete and recreate instead.
- **Multi-line SQL or YAML doesn't belong typed directly into the terminal.** The terminal only parses shell syntax. Either write it into a file via your editor, or use a heredoc (`cat > file << 'EOF' ... EOF`) to safely write multi-line content from the terminal.

---

## 6. Where things actually run (this tripped me up a lot)

**The terminal always operates on "wherever you currently are" (`pwd`).** Every command — `dbt run`, `dbt seed`, `git status` — acts on the current folder. dbt commands specifically need to run from inside the project folder (where `dbt_project.yml` lives), or dbt won't find the project at all. Most of the folder-nesting mess earlier came from running a command from the wrong directory without checking `pwd` first.

**`.sql` and `.yml` files aren't "run" directly by you.** You write and save them in VS Code; they only do anything when a terminal command (`dbt run`, `dbt test`) reads them from disk. The file and the command are two separate things that meet only when you invoke dbt.

**Three unrelated tools that are easy to conflate:**
- **The DuckDB shell** (`duckdb dev.duckdb`) is a manual inspection tool only — not part of the pipeline. You open it to poke around and close it; nothing typed there is saved or affects the project.
- **`.sql` files in `models/`** are the actual transformation logic dbt runs for real every time.
- **`.yml` files** (like `schema.yml`) aren't SQL and don't get "converted" from it — they're separate configuration dbt reads to know what tests to generate. SQL and YAML sit side by side doing different jobs, not one becoming the other.

## 7. Terminal vs VS Code Source Control panel

The Source Control panel isn't a different tool — it's a visual wrapper around the same git commands typed in a terminal.

| What you want to do | Terminal command | VS Code Source Control panel |
|---|---|---|
| See what's changed | `git status` | Files with changes appear automatically, marked M/U/A |
| Stage a file | `git add <file>` | Click `+` next to the file, or `+` at the top to stage all |
| Commit staged changes | `git commit -m "message"` | Type a message in the box at top, click the checkmark (✓) |
| Push to GitHub | `git push` | Click "Sync Changes" or the "..." menu → Push |
| Create a new branch | `git checkout -b my-branch` | Click the branch name in the bottom-left status bar → "Create new branch" |

Worth doing the first several commits via the terminal specifically, even though the panel is faster — if you only click buttons, "I clicked the checkmark" isn't an answer to "walk me through your git workflow" in an interview.

## 8. Where you are right now

You have a working local pipeline:
```
raw CSVs (seeds/) → dbt seed → DuckDB tables → dbt run (stg_orders model) → dbt test (unique + not_null checks)
```
This is genuinely the hard part conceptually. What's left is largely mechanical:

## 9. Next steps
1. `rm -rf models/example` — remove the leftover placeholder model/tests causing noise
2. Re-run `dbt run` and `dbt test` — should be 100% clean
3. Add a `.gitignore` excluding `venv/` and `dev.duckdb` (a virtual env and a binary database file don't belong in git history)
4. Write `.github/workflows/ci.yml` to run `dbt seed && dbt run && dbt test` automatically on every pull request
5. Push to GitHub, open a PR, and watch the check run — first time seeing a real CI pipeline you wrote actually execute
