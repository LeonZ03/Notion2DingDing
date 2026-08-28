package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/handler"
	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/localtool"
	"github.com/LeonZ03/Notion2DingDing/apps/native-host/internal/protocol"
)

const maxMessageBytes = 96 * 1024 * 1024

type requestHandler interface {
	Handle(protocol.Request) protocol.Response
}

func main() {
	service := localtool.New()
	defer service.Shutdown()
	messageHandler := handler.New(service)
	for {
		if err := processMessage(os.Stdin, os.Stdout, messageHandler); err != nil {
			if errors.Is(err, io.EOF) {
				return
			}

			fmt.Fprintln(os.Stderr, err)
			return
		}
	}
}

func processMessage(input io.Reader, output io.Writer, messageHandler requestHandler) error {
	var messageLength uint32
	if err := binary.Read(input, binary.LittleEndian, &messageLength); err != nil {
		return err
	}

	if messageLength == 0 || messageLength > maxMessageBytes {
		return fmt.Errorf("invalid native message length: %d", messageLength)
	}

	payload := make([]byte, messageLength)
	if _, err := io.ReadFull(input, payload); err != nil {
		return fmt.Errorf("read native message: %w", err)
	}

	var request protocol.Request
	if err := json.Unmarshal(payload, &request); err != nil {
		return writeResponse(output, protocol.Failure("", "invalid_json", "请求不是有效 JSON。"))
	}

	return writeResponse(output, messageHandler.Handle(request))
}

func writeResponse(output io.Writer, response protocol.Response) error {
	payload, err := json.Marshal(response)
	if err != nil {
		return fmt.Errorf("encode native response: %w", err)
	}

	if err := binary.Write(output, binary.LittleEndian, uint32(len(payload))); err != nil {
		return fmt.Errorf("write native response length: %w", err)
	}

	if _, err := output.Write(payload); err != nil {
		return fmt.Errorf("write native response: %w", err)
	}

	return nil
}
