package udp

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"errors"
	"fmt"
)

type Direction uint8

const (
	DirectionClientToServer Direction = 0x01
	DirectionServerToClient Direction = 0x02
)

type CryptoSession struct {
	sessionID uint64
	aead      cipher.AEAD
}

func NewCryptoSession(sessionID uint64, key []byte) (*CryptoSession, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("session key must be 32 bytes, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &CryptoSession{
		sessionID: sessionID,
		aead:      aead,
	}, nil
}

func (s *CryptoSession) Seal(header Header, payload []byte, direction Direction) ([]byte, error) {
	if header.SessionID != s.sessionID {
		return nil, errors.New("session ID mismatch")
	}
	header.Version = ProtocolVersion
	header.PayloadLen = uint16(len(payload))
	headerBytes := header.MarshalBinary()
	ciphertext := s.aead.Seal(nil, Nonce(header.SessionID, direction, header.Sequence), payload, headerBytes)
	return append(headerBytes, ciphertext...), nil
}

func (s *CryptoSession) Open(datagram []byte, direction Direction) (Header, []byte, error) {
	header, err := ParseHeader(datagram)
	if err != nil {
		return Header{}, nil, err
	}
	if header.SessionID != s.sessionID {
		return Header{}, nil, errors.New("session ID mismatch")
	}
	if len(datagram) != HeaderSize+int(header.PayloadLen)+TagSize {
		return Header{}, nil, errors.New("packet length does not match payload_len")
	}
	plaintext, err := s.aead.Open(nil, Nonce(header.SessionID, direction, header.Sequence), datagram[HeaderSize:], datagram[:HeaderSize])
	if err != nil {
		return Header{}, nil, err
	}
	return header, plaintext, nil
}

func Nonce(sessionID uint64, direction Direction, sequence uint32) []byte {
	var nonce [12]byte
	var sessionBuf [8]byte
	binary.BigEndian.PutUint64(sessionBuf[:], sessionID)
	copy(nonce[0:7], sessionBuf[1:])
	nonce[7] = byte(direction)
	binary.BigEndian.PutUint32(nonce[8:12], sequence)
	return nonce[:]
}
