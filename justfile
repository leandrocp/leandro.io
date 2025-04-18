default:
    @just --list

dev:
    npx http-server . -p 8000 --ext-fallback

format:
    npx prettier . --write
