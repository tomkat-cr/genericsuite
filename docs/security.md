# Security

## Security Considerations

- **Never commit `.env` files** — only `.env.example` templates are committed
- All secrets (API keys, DB credentials, JWT secrets) must be in `.env` files
- HTTPS required for all production deployments
- Run `npm audit` / `pip-audit` regularly for dependency vulnerability scanning
- CORS settings are configured per-environment via `APP_CORS_ORIGIN_{STAGE}` env vars

## Important Notes

- When this file is updated, warn the user to update `security.md` file in all projects.
