FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go build -o /out/web ./main.go

FROM alpine:3.20
COPY --from=build /out/web /usr/local/bin/web
EXPOSE 8080
CMD ["/usr/local/bin/web"]
