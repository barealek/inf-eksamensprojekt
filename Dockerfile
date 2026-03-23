FROM oven/bun:1 AS frontend

WORKDIR /app/frontend/
COPY frontend/ /app/frontend/
RUN bun install
RUN bun run build

FROM golang:1-alpine

WORKDIR /app
COPY --from=frontend /app/frontend/dist static/
COPY go.* .
RUN go mod download -x

COPY . .

RUN go build -o /bin/app .

CMD ["/bin/app"]
