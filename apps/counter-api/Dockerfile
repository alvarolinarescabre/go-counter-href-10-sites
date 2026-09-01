FROM golang:1.26-alpine AS builder

WORKDIR /src
RUN apk add --no-cache ca-certificates
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/counter-api .

FROM scratch

COPY --from=builder /out/counter-api /usr/local/bin/counter-api
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
EXPOSE 80
ENV PORT=80

ENTRYPOINT ["/usr/local/bin/counter-api"]
