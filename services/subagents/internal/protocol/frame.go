package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"google.golang.org/protobuf/proto"
)

const (
	ProtocolMajor = 1
	ProtocolMinor = 1
	MaxFrameSize  = 64 * 1024
)

var (
	ErrFrameTooLarge      = errors.New("protobuf frame exceeds 64 KiB")
	ErrUnsupportedVersion = errors.New("unsupported protocol major version")
)

func ReadEnvelope(reader io.Reader) (*subagentsv1.Envelope, error) {
	var prefix [4]byte
	if _, err := io.ReadFull(reader, prefix[:]); err != nil {
		return nil, fmt.Errorf("read frame prefix: %w", err)
	}
	length := binary.BigEndian.Uint32(prefix[:])
	if length == 0 {
		return nil, errors.New("empty protobuf frame")
	}
	if length > MaxFrameSize {
		return nil, ErrFrameTooLarge
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, fmt.Errorf("read frame payload: %w", err)
	}
	envelope := new(subagentsv1.Envelope)
	if err := proto.Unmarshal(payload, envelope); err != nil {
		return nil, fmt.Errorf("decode protobuf envelope: %w", err)
	}
	if envelope.ProtocolMajor != ProtocolMajor {
		return nil, fmt.Errorf("%w: %d", ErrUnsupportedVersion, envelope.ProtocolMajor)
	}
	return envelope, nil
}

func WriteEnvelope(writer io.Writer, envelope *subagentsv1.Envelope) error {
	if envelope == nil {
		return errors.New("envelope is required")
	}
	payload, err := (proto.MarshalOptions{Deterministic: true}).Marshal(envelope)
	if err != nil {
		return fmt.Errorf("encode protobuf envelope: %w", err)
	}
	if len(payload) == 0 || len(payload) > MaxFrameSize {
		return ErrFrameTooLarge
	}
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(len(payload)))
	if err := writeFull(writer, prefix[:]); err != nil {
		return fmt.Errorf("write frame prefix: %w", err)
	}
	if err := writeFull(writer, payload); err != nil {
		return fmt.Errorf("write frame payload: %w", err)
	}
	return nil
}

func writeFull(writer io.Writer, payload []byte) error {
	for len(payload) != 0 {
		written, err := writer.Write(payload)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		payload = payload[written:]
	}
	return nil
}
