default:
    @just --list

dev:
    python3 -m http.server 8000 

format:
    tidy -i -w 4 -m *.html
