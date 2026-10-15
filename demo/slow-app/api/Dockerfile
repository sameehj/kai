FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN go build -o /out/api ./main.go

FROM alpine:3.20
COPY --from=build /out/api /usr/local/bin/api
EXPOSE 8081
CMD ["/usr/local/bin/api"]
