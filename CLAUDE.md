# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MCP Agent Mail is an HTTP-only FastMCP server providing a mail-like coordination layer for coding agents. It gives agents memorable identities, inbox/outbox messaging, searchable message history, and voluntary file reservation "leases" to avoid conflicts. Think of it as asynchronous email + directory + change-intent signaling, backed by Git (for human-auditable artifacts) and SQLite/PostgreSQL (for indexing and queries).

## Development Commands

### Environment Setup
```bash
# Install uv if needed
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Create Python 3.14 venv and install dependencies
uv python install 3.14
uv venv -p 3.14
source .venv/bin/activate
uv sync
```

### Running the Server
```bash
# Development server (HTTP-only)
uv run python -m mcp_agent_mail.cli serve-http --host 127.0.0.1 --port 8765

# Or via uvicorn directly
uv run uvicorn mcp_agent_mail.http:build_http_app --factory --host 127.0.0.1 --port 8765

# Production (with token)
scripts/run_server_with_token.sh
```

### Testing
```bash
# Run all tests
uv run pytest

# Run with coverage
uv run pytest --cov=mcp_agent_mail --cov-report=term-missing

# Run specific test file
uv run pytest tests/test_server.py

# Quick endpoint smoke test (server must be running)
bash scripts/test_endpoints.sh
```

### Code Quality
```bash
# Lint and auto-fix (ALWAYS run after making changes)
ruff check --fix --unsafe-fixes

# Type checking (ALWAYS run after making changes)
uvx ty check
```

### Database Management
```bash
# Ensure schema exists (automatic on first run)
uv run python -m mcp_agent_mail.cli migrate

# List projects
uv run python -m mcp_agent_mail.cli list-projects --include-agents
```

### CLI Commands
```bash
# Install pre-commit guard into a repo
uv run python -m mcp_agent_mail.cli guard install /abs/path/backend /abs/path/backend

# List pending acknowledgements
uv run python -m mcp_agent_mail.cli acks pending /abs/path/backend AgentName --limit 10

# List file reservations
uv run python -m mcp_agent_mail.cli file_reservations list /abs/path/backend --active-only
```

## Architecture

### Dual Persistence Model
1. **Git Archive**: Human-readable Markdown files in a per-project Git repo
   - Messages stored as `messages/YYYY/MM/{id}.md` with JSON frontmatter
   - Inbox/outbox copies under `agents/{AgentName}/inbox/` and `outbox/`
   - File reservations as JSON under `file_reservations/`
   - Attachments (WebP) under `attachments/xx/{sha1}.webp`

2. **SQLite/PostgreSQL Database**: Fast indexing and queries
   - FTS5 (SQLite) or tsvector (PostgreSQL) for full-text search
   - Tables: projects, agents, messages, message_recipients, file_reservations, agent_links, project_sibling_suggestions
   - See `src/mcp_agent_mail/models.py` for SQLModel definitions

### Core Modules
- **app.py**: FastMCP application factory, tool definitions, macros, business logic
- **storage.py**: Git archive operations, attachment processing, file locking
- **db.py**: Database session management, schema initialization
- **http.py**: FastAPI wrapper, middleware (auth, CORS, rate limiting), web UI routes
- **models.py**: SQLModel data models
- **config.py**: Configuration using python-decouple (reads from `.env`)
- **guard.py**: Pre-commit hook for file reservation enforcement
- **llm.py**: LiteLLM integration for thread summaries and project discovery

### Tool Clustering
Tools are organized into clusters for better discoverability:
- **infrastructure**: health_check, ensure_project
- **identity**: register_agent, whois, create_agent_identity, set_contact_policy
- **messaging**: send_message, reply_message, fetch_inbox, mark_message_read, acknowledge_message
- **contact**: request_contact, respond_contact, list_contacts
- **search**: search_messages, summarize_thread, summarize_threads
- **file_reservations**: file_reservation_paths, release_file_reservations, renew_file_reservations, install_precommit_guard
- **workflow_macros**: macro_start_session, macro_prepare_thread, macro_file_reservation_cycle, macro_contact_handshake

## Key Architectural Patterns

### Async Context Management
- One `AsyncSession` per request/task; never share across concurrent operations
- Use `async with get_session() as session:` for automatic cleanup
- Archive writes use project-level `.archive.lock` (via AsyncFileLock)
- Git commits use repo-level `.commit.lock` to serialize across projects

### File Locking Strategy
- **Per-project archive lock**: `ProjectArchive.lock_path` prevents concurrent writes to same project
- **Repo-level commit lock**: Serializes Git index/commit operations across all projects
- **Stale lock cleanup**: Locks older than `stale_timeout_seconds` are automatically cleaned
- See `storage.py::AsyncFileLock` for implementation

### Message Flow
1. Tool call → validate sender/recipients exist
2. Process attachments (convert images to WebP, handle inline vs file storage)
3. Create message row in DB (auto-assigned ID)
4. Acquire archive lock for project
5. Write canonical message to `messages/YYYY/MM/{id}.md`
6. Write inbox copies to each recipient's `agents/{name}/inbox/`
7. Write outbox copy to sender's `agents/{name}/outbox/`
8. Git add + commit with descriptive message
9. Release archive lock
10. Return delivery summary

### Contact Policy Enforcement
- **open**: Accept any targeted messages in the project
- **auto** (default): Allow messages when shared context exists (same thread, overlapping file reservations, recent contact)
- **contacts_only**: Require approved AgentLink first
- **block_all**: Reject all new contacts

Auto-allow heuristics (bypass explicit contact request):
- Same thread participants
- Recent overlapping file reservations
- Recent prior contact within TTL

### File Reservations (Advisory Leases)
- Declared via `file_reservation_paths(project_key, agent_name, paths[], exclusive, ttl_seconds)`
- Conflicts detected on overlap with active exclusive reservations
- Optional enforcement via pre-commit hook (`install_precommit_guard`)
- JSON artifacts written to Git for audit trail
- Database tracks active/released/expired state

## Configuration

All config loaded from `.env` via `python-decouple` (never use `os.getenv` or `dotenv`). The configuration system gracefully falls back to environment variables if `.env` doesn't exist, making it container-friendly:

```python
from decouple import Config as DecoupleConfig, RepositoryEnv, config as decouple_autoconfig

# In config.py, we check if .env exists and fall back to environment variables if not
if Path(".env").exists():
    decouple_config = DecoupleConfig(RepositoryEnv(".env"))
else:
    decouple_config = decouple_autoconfig  # Uses environment variables only
```

Key variables (see `.env.example` for full list):
- `DATABASE_URL`: SQLite (`sqlite+aiosqlite:///...`) or PostgreSQL (`postgresql+asyncpg://...`)
- `STORAGE_ROOT`: Root for Git archive and attachments (default: `./storage`)
- `HTTP_HOST`, `HTTP_PORT`, `HTTP_PATH`: Server bind settings
- `HTTP_BEARER_TOKEN`: Static bearer token (when JWT disabled)
- `HTTP_JWT_ENABLED`, `HTTP_JWT_JWKS_URL`: JWT authentication
- `LLM_ENABLED`, `LLM_DEFAULT_MODEL`: LiteLLM for summaries and discovery
- `CONVERT_IMAGES`, `INLINE_IMAGE_MAX_BYTES`: Image processing settings

## Database Patterns

### Using SQLModel + Async SQLAlchemy

**Do:**
- Use `create_async_engine()` and `async_sessionmaker()`
- `async with AsyncSession(...) as session:` for auto-cleanup
- `await` every DB operation: `await session.execute(...)`, `await session.commit()`
- One AsyncSession per request/task (no sharing across concurrent operations)
- Explicitly load relationships: `selectinload()`, `joinedload()`, or `await obj.awaitable_attrs.rel`
- `await engine.dispose()` on shutdown

**Don't:**
- Don't reuse AsyncSession across concurrent tasks
- Don't rely on lazy loads (will error in async code)
- Don't mix sync drivers with async sessions
- Don't "double-await" result helpers (`.all()` is sync after the await on execute)

### PostgreSQL-specific
When `DATABASE_URL` contains `postgresql`:
- Auto-configures `tsvector` search indexes for full-text search
- Uses Postgres array and JSON operators
- Leverage `asyncpg` driver features
- See `third_party_docs/POSTGRES18_AND_PYTHON_BEST_PRACTICES.md`

## Testing Patterns

- Tests use `pytest-asyncio` with `asyncio_mode = "auto"`
- Fixtures in `tests/conftest.py` provide isolated DB sessions and temp storage
- Each test gets a fresh database and Git archive
- Mock LLM calls unless testing LLM integration specifically
- Use `AsyncClient` from httpx for HTTP endpoint tests

Example test structure:
```python
async def test_send_message(session, project, sender_agent, recipient_agent):
    # Arrange
    archive = await ensure_archive(settings, project.slug)

    # Act
    result = await send_message(
        project_key=project.human_key,
        sender_name=sender_agent.name,
        to=[recipient_agent.name],
        subject="Test",
        body_md="Test message"
    )

    # Assert
    assert result["count"] == 1
    # Verify Git artifact exists
    # Verify DB row created
```

## Web UI

Built-in server-rendered UI at `/mail`:
- Templates in `src/mcp_agent_mail/templates/` (Jinja2)
- Tailwind CSS, Alpine.js, Marked, Prism loaded via CDN
- Routes: `/mail`, `/mail/{project}`, `/mail/{project}/inbox/{agent}`, `/mail/{project}/message/{id}`
- Human Overseer: `/mail/{project}/overseer/compose` for human→agent messages
- Authentication: Respects `HTTP_BEARER_TOKEN` or `HTTP_BASIC_AUTH_*` settings

## Common Workflows

### Adding a New Tool
1. Define function in `app.py` with proper type hints and docstring
2. Decorate with `@_track_metrics()` and assign to cluster
3. Register with `_register_tool(name, metadata)` in tool metadata dict
4. Add to FastMCP via `@mcp.tool()` decorator
5. Add tests in `tests/test_*.py`
6. Run `ruff check --fix --unsafe-fixes` and `uvx ty check`

### Adding a New Resource
1. Define handler function in `app.py` with `@mcp.resource()` decorator
2. Parse URI parameters and validate
3. Query database and return formatted dict
4. Add tests verifying URI parsing and response format

### Modifying Database Schema
1. Update SQLModel definitions in `models.py`
2. Delete existing `storage.sqlite3` (and WAL/SHM files) during development
3. Run `uv run python -m mcp_agent_mail.cli migrate`
4. Update related storage/archive functions if needed
5. Add migration logic if schema change affects existing deployments

### Adding Middleware
1. Create middleware class in `http.py` extending `BaseHTTPMiddleware`
2. Add to `build_http_app()` via `app.add_middleware()`
3. Test with `httpx.AsyncClient` in tests
4. Document config variables in `.env.example`

## Deployment Patterns

### Local Development
- Use SQLite: `DATABASE_URL=sqlite+aiosqlite:///./storage.sqlite3`
- No auth: `HTTP_ALLOW_LOCALHOST_UNAUTHENTICATED=true`
- Enable request logging: `HTTP_REQUEST_LOG_ENABLED=true`, `TOOLS_LOG_ENABLED=true`

### Production
- Use PostgreSQL: `DATABASE_URL=postgresql+asyncpg://user:pass@host/db`
- Enable JWT: `HTTP_JWT_ENABLED=true`, `HTTP_JWT_JWKS_URL=...`
- Or use static bearer: `HTTP_BEARER_TOKEN=<secure-token>`
- Disable localhost bypass: `HTTP_ALLOW_LOCALHOST_UNAUTHENTICATED=false`
- Enable Basic Auth for Web UI: `HTTP_BASIC_AUTH_ENABLED=true`
- Run with gunicorn: `gunicorn -c deploy/gunicorn.conf.py mcp_agent_mail.http:build_http_app --factory`

### Docker
```bash
docker compose up --build
# Or multi-arch build
docker buildx build --platform linux/amd64,linux/arm64 -t your-registry/mcp-agent-mail:latest --push .
```

### Systemd
1. Copy project to `/opt/mcp-agent-mail`
2. Create `/etc/mcp-agent-mail.env` from `deploy/env/production.env`
3. Install `deploy/systemd/mcp-agent-mail.service` to `/etc/systemd/system/`
4. `sudo systemctl daemon-reload && sudo systemctl enable mcp-agent-mail && sudo systemctl start mcp-agent-mail`

## Important Constraints

### Python 3.14 Only
- No backwards compatibility concerns
- Use latest Python features freely
- Only test against 3.14

### No File Deletion Without Permission
- Never delete files without explicit user approval
- This includes test files, temporary files, or files you created
- Ask first, even if it seems safe

### No Script-Based Code Modifications
- Never run scripts that process/change code files via regex
- Make changes manually, even when many instances need fixing
- Use parallel subagents for simple repetitive changes
- Complex changes must be done methodically by hand

### Avoid File Proliferation
- Never create versioned files (e.g., `file_v2.py`, `file_improved.py`)
- Modify existing files in place
- New files only for genuinely new functionality
- High bar for creating new code files

### Configuration Management
- `.env` file is optional - falls back to environment variables if missing
- Never overwrite existing `.env` if it exists
- Use `.env.example` as template for new deployments
- In containers, can use environment variables directly without mounting `.env`

### Code Quality Requirements
After ANY substantive code changes:
1. Run `ruff check --fix --unsafe-fixes` (lint and auto-fix)
2. Run `uvx ty check` (type checking)
3. Fix all errors/warnings before committing

### Git Safety
- Never run destructive Git commands without explicit approval
- Forbidden: `git reset --hard`, `git clean -fd`, force push to main/master
- Always ask before deleting or overwriting code/data
- Use safer alternatives first: `git stash`, `git diff`, backups

## Package Management
- **ONLY** use `uv` (never pip)
- **ONLY** use `pyproject.toml` (never requirements.txt)
- Dependencies managed via `uv sync`
- Dev dependencies in `[project.optional-dependencies]` and `[dependency-groups]`

## Rich Console Output
- Use `rich` library for all console output
- Colorful, informative, stylish output preferred
- See `src/mcp_agent_mail/rich_logger.py` for patterns

## External Documentation
- FastMCP best practices: `third_party_docs/PYTHON_FASTMCP_BEST_PRACTICES.md`
- FastMCP API reference: `third_party_docs/fastmcp_distilled_docs.md`
- MCP protocol specs: `third_party_docs/mcp_protocol_specs.md`
- PostgreSQL patterns: `third_party_docs/POSTGRES18_AND_PYTHON_BEST_PRACTICES.md`

## Integration with Agent Tools
Auto-detection scripts in `scripts/`:
- `integrate_claude_code.sh`: Configure Claude Code MCP client
- `integrate_codex_cli.sh`: Configure Codex CLI
- `integrate_cursor.sh`: Configure Cursor editor
- `integrate_gemini_cli.sh`: Configure Gemini CLI
- `integrate_cline.sh`: Configure Cline extension
- `integrate_windsurf.sh`: Configure Windsurf
- `integrate_opencode.sh`: Configure OpenCode

Run all: `scripts/automatically_detect_all_installed_coding_agents_and_install_mcp_agent_mail_in_all.sh`

## MCP Server Usage (for agents working in this repo)

When working on this codebase, register as an agent and coordinate with others:

```bash
# Set your agent name for pre-commit guard
export AGENT_NAME=YourAgentName

# Example tool usage (if MCP server is running locally)
# Register identity
register_agent(project_key="/abs/path/to/mcp_agent_mail", program="Claude Code", model="sonnet-4-5", name="BlueLake")

# Reserve files before editing
file_reservation_paths(project_key="/abs/path/to/mcp_agent_mail", agent_name="BlueLake", paths=["src/mcp_agent_mail/app.py"], exclusive=true, ttl_seconds=3600)

# Send message to another agent
send_message(project_key="/abs/path/to/mcp_agent_mail", sender_name="BlueLake", to=["GreenCastle"], subject="Working on new feature", body_md="I'm adding support for...")

# Check inbox
fetch_inbox(project_key="/abs/path/to/mcp_agent_mail", agent_name="BlueLake", limit=10)
```

## Troubleshooting

### Database Issues
- SQLite locks: Ensure only one writer at a time; check for stale lock files
- PostgreSQL connection: Verify `DATABASE_URL` and network connectivity
- FTS not working: Check if FTS5 available (SQLite) or tsvector configured (PostgreSQL)

### Git Archive Issues
- Stale locks: Archive locks auto-cleanup after `stale_timeout_seconds`
- Commit failures: Check Git author config in `.env` (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`)
- Missing files: Ensure `STORAGE_ROOT` directory exists and is writable

### HTTP/Auth Issues
- 401 on localhost: Set `HTTP_ALLOW_LOCALHOST_UNAUTHENTICATED=true` for dev
- JWT errors: Verify `kid` in token matches `HTTP_JWT_JWKS_URL` keys
- CORS errors: Enable and configure `HTTP_CORS_*` variables

### Testing Issues
- Async warnings: Ensure `pytest-asyncio` installed and `asyncio_mode = "auto"` set
- Temp file cleanup: Fixtures should use `tmp_path` from pytest
- Database isolation: Each test should get fresh session from conftest fixtures
