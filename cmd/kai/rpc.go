package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/daemon"
)

func rpcConn(cfg config.Config) (net.Conn, *json.Encoder, *json.Decoder, error) {
	conn, err := net.Dial("unix", cfg.Daemon.SocketPath)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("connect daemon: %w", err)
	}
	return conn, json.NewEncoder(conn), json.NewDecoder(conn), nil
}

func rpcCall(cfg config.Config, req daemon.RPCRequest) (*daemon.RPCResponse, error) {
	conn, enc, dec, err := rpcConn(cfg)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := enc.Encode(req); err != nil {
		return nil, err
	}
	var resp daemon.RPCResponse
	if err := dec.Decode(&resp); err != nil {
		return nil, err
	}
	if !resp.OK {
		if resp.Error == "" {
			return nil, errors.New("daemon request failed")
		}
		return nil, errors.New(resp.Error)
	}
	return &resp, nil
}
