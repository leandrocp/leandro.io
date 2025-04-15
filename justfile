default:
    @just --list

dev:
    python3 -m http.server 8000

format:
    npx prettier . --write
