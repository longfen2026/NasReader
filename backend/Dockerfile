FROM golang:1.22-alpine AS builder

WORKDIR /app

# 先单独下载依赖，命中缓存层；go.sum 已入库，构建期不再 tidy，保证可复现
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# 纯 Go 静态编译，跨平台秒编通过
RUN CGO_ENABLED=0 GOOS=linux go build -mod=readonly -ldflags="-w -s" -o reader-server .

FROM alpine:latest
WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata

# 创建非 root 用户运行服务，降低容器逃逸后的影响面
RUN addgroup -S reader && adduser -S -G reader -H -u 10001 reader

COPY --from=builder /app/reader-server .

# 预建数据/上传目录并归属非 root 用户；宿主机挂载卷需保证同一 UID 可写
RUN mkdir -p /app/data /app/uploads && chown -R reader:reader /app

USER reader

EXPOSE 8080
CMD ["./reader-server"]