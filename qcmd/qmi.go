// Minimal QMI client over QRTR (AF_QIPCRTR) - no glib/libqmi needed.
// Used for NAS "Get Cell Location Info" (0x0043) to build the neighbour-cell scan.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	afQIPCRTR    = 42
	qrtrPortCtrl = 0xfffffffe
	qrtrNewLook  = 10
	qrtrNewSrv   = 4
)

type sockaddrQrtr struct {
	Family uint16
	_      uint16
	Node   uint32
	Port   uint32
}

type qrtrSock struct{ fd int }

func qrtrOpen() (*qrtrSock, error) {
	fd, err := syscall.Socket(afQIPCRTR, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return nil, err
	}
	tv := syscall.Timeval{Sec: 8}
	_ = syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	return &qrtrSock{fd: fd}, nil
}

func (q *qrtrSock) close() { syscall.Close(q.fd) }

func (q *qrtrSock) localNode() (uint32, error) {
	var sa sockaddrQrtr
	l := uint32(unsafe.Sizeof(sa))
	_, _, e := syscall.Syscall(syscall.SYS_GETSOCKNAME, uintptr(q.fd), uintptr(unsafe.Pointer(&sa)), uintptr(unsafe.Pointer(&l)))
	if e != 0 {
		return 0, e
	}
	return sa.Node, nil
}

func (q *qrtrSock) sendTo(node, port uint32, b []byte) error {
	sa := sockaddrQrtr{Family: afQIPCRTR, Node: node, Port: port}
	_, _, e := syscall.Syscall6(syscall.SYS_SENDTO, uintptr(q.fd), uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)), 0, uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa))
	if e != 0 {
		return e
	}
	return nil
}

func (q *qrtrSock) recv() ([]byte, sockaddrQrtr, error) {
	buf := make([]byte, 65536)
	var sa sockaddrQrtr
	l := uint32(unsafe.Sizeof(sa))
	n, _, e := syscall.Syscall6(syscall.SYS_RECVFROM, uintptr(q.fd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, uintptr(unsafe.Pointer(&sa)), uintptr(unsafe.Pointer(&l)))
	if e != 0 {
		return nil, sa, e
	}
	return buf[:n], sa, nil
}

// lookup finds a QMI service (e.g. 3 = NAS) through the QRTR name server.
func (q *qrtrSock) lookup(service uint32) (uint32, uint32, error) {
	// autobind by sending; learn our node first
	pkt := make([]byte, 20)
	binary.LittleEndian.PutUint32(pkt[0:], qrtrNewLook)
	binary.LittleEndian.PutUint32(pkt[4:], service)
	// instance 0 / node 0 / port 0 = wildcard
	node, err := q.localNode()
	if err != nil {
		return 0, 0, err
	}
	if err := q.sendTo(node, qrtrPortCtrl, pkt); err != nil {
		return 0, 0, err
	}
	if node == 0 { // node is only known after autobind
		node, _ = q.localNode()
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		b, _, err := q.recv()
		if err != nil {
			return 0, 0, err
		}
		if len(b) < 20 || binary.LittleEndian.Uint32(b[0:]) != qrtrNewSrv {
			continue
		}
		svc := binary.LittleEndian.Uint32(b[4:])
		if svc == 0 {
			break // end of lookup results
		}
		if svc == service {
			return binary.LittleEndian.Uint32(b[12:]), binary.LittleEndian.Uint32(b[16:]), nil
		}
	}
	return 0, 0, errors.New("service not found")
}

// qmiRequest sends a QMI service request (no TLVs) and returns the response TLVs.
func qmiRequest(service uint32, msgID uint16) (map[byte][]byte, error) {
	q, err := qrtrOpen()
	if err != nil {
		return nil, err
	}
	defer q.close()
	node, port, err := q.lookup(service)
	if err != nil {
		return nil, err
	}
	txn := uint16(time.Now().UnixNano()&0x7fff) | 1
	req := make([]byte, 7)
	req[0] = 0x00 // request
	binary.LittleEndian.PutUint16(req[1:], txn)
	binary.LittleEndian.PutUint16(req[3:], msgID)
	binary.LittleEndian.PutUint16(req[5:], 0)
	if err := q.sendTo(node, port, req); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		b, sa, err := q.recv()
		if err != nil {
			return nil, err
		}
		if sa.Node != node || sa.Port != port || len(b) < 7 {
			continue
		}
		if b[0] != 0x02 || binary.LittleEndian.Uint16(b[1:]) != txn || binary.LittleEndian.Uint16(b[3:]) != msgID {
			continue // indication or other transaction
		}
		tl := int(binary.LittleEndian.Uint16(b[5:]))
		body := b[7:]
		if tl < len(body) {
			body = body[:tl]
		}
		tlvs := map[byte][]byte{}
		for len(body) >= 3 {
			t, l := body[0], int(binary.LittleEndian.Uint16(body[1:]))
			if 3+l > len(body) {
				break
			}
			tlvs[t] = body[3 : 3+l]
			body = body[3+l:]
		}
		if r, ok := tlvs[0x02]; ok && len(r) >= 4 && binary.LittleEndian.Uint16(r[0:]) != 0 {
			return tlvs, fmt.Errorf("QMI error %d", binary.LittleEndian.Uint16(r[2:]))
		}
		return tlvs, nil
	}
	return nil, errors.New("timeout")
}

func bcdPLMN(b []byte) (string, string) {
	if len(b) < 3 {
		return "-", "-"
	}
	d := func(x byte) string {
		if x == 0xF {
			return ""
		}
		return fmt.Sprint(x)
	}
	mcc := d(b[0]&0xF) + d(b[0]>>4) + d(b[1]&0xF)
	mnc := d(b[2]&0xF) + d(b[2]>>4) + d(b[1]>>4)
	return mcc, mnc
}

// LTE EARFCN (DL) -> band
var lteBands = []struct{ band, lo, hi int }{
	{1, 0, 599}, {2, 600, 1199}, {3, 1200, 1949}, {4, 1950, 2399}, {5, 2400, 2649}, {7, 2750, 3449},
	{8, 3450, 3799}, {12, 5010, 5179}, {13, 5180, 5279}, {14, 5280, 5379}, {17, 5730, 5849}, {18, 5850, 5999},
	{19, 6000, 6149}, {20, 6150, 6449}, {25, 8040, 8689}, {26, 8690, 9039}, {28, 9210, 9659}, {29, 9660, 9769},
	{30, 9770, 9869}, {32, 9920, 10359}, {34, 36200, 36349}, {38, 37750, 38249}, {39, 38250, 38649},
	{40, 38650, 39649}, {41, 39650, 41589}, {42, 41590, 43589}, {43, 43590, 45589}, {46, 46790, 54539},
	{66, 66436, 67335}, {71, 68586, 68935},
}

func lteBand(earfcn int) string {
	for _, b := range lteBands {
		if earfcn >= b.lo && earfcn <= b.hi {
			return fmt.Sprint(b.band)
		}
	}
	return "-"
}

// cellScan builds Quectel-style +QSCAN lines from NAS Get Cell Location Info.
func cellScan() string {
	tlvs, err := qmiRequest(3, 0x0043)
	if err != nil {
		return "ERROR"
	}
	if os.Getenv("QCMD_DEBUG") == "1" {
		for t, v := range tlvs {
			fmt.Fprintf(os.Stderr, "TLV 0x%02X len=%d % x\n", t, len(v), v)
		}
	}
	le16 := func(b []byte) int { return int(binary.LittleEndian.Uint16(b)) }
	s16 := func(b []byte) int { return int(int16(binary.LittleEndian.Uint16(b))) }
	r := func(v int) int { // 0.1 dB units, rounded
		if v < 0 {
			return (v - 5) / 10
		}
		return (v + 5) / 10
	}
	var out []string
	seen := map[string]bool{}
	add := func(l string, key string) {
		if !seen[key] {
			seen[key] = true
			out = append(out, l)
		}
	}
	mcc, mnc := "-", "-"

	// NR5G serving cell (0x2F) + ARFCN (0x2E)
	if c, ok := tlvs[0x2F]; ok && len(c) >= 22 {
		mcc, mnc = bcdPLMN(c[0:3])
		tac := int(c[3])<<16 | int(c[4])<<8 | int(c[5])
		gcid := binary.LittleEndian.Uint64(c[6:14])
		pci := le16(c[14:16])
		rsrq, rsrp, snr := s16(c[16:18]), s16(c[18:20]), s16(c[20:22])
		arfcn := "-"
		if a, ok := tlvs[0x2E]; ok && len(a) >= 4 {
			arfcn = fmt.Sprint(binary.LittleEndian.Uint32(a))
		}
		band := field(cri("band"), `NR5G Band (\d+)`)
		add(fmt.Sprintf("+QSCAN: \"NR5G\",%s,%s,%s,%d,%d,%d,%d,30,%X,%X,-,%s", mcc, mnc, arfcn, pci, r(rsrp), r(rsrq), r(snr), gcid, tac, dash(band)), "NR"+arfcn+fmt.Sprint(pci))
	}

	// LTE intra-frequency (0x13): serving + neighbours on the same EARFCN
	if c, ok := tlvs[0x13]; ok && len(c) >= 19 {
		lm, ln := bcdPLMN(c[1:4])
		if lm != "" {
			mcc, mnc = lm, ln
		}
		tac := le16(c[4:6])
		gcid := binary.LittleEndian.Uint32(c[6:10])
		earfcn := le16(c[10:12])
		servPci := le16(c[12:14])
		n := int(c[18])
		p := c[19:]
		for i := 0; i < n && len(p) >= 10; i++ {
			pci, rsrq, rsrp := le16(p[0:2]), s16(p[2:4]), s16(p[4:6])
			cid, t := "-", "-"
			if pci == servPci {
				cid, t = fmt.Sprintf("%X", gcid), fmt.Sprintf("%X", tac)
			}
			add(fmt.Sprintf("+QSCAN: \"LTE\",%s,%s,%d,%d,%d,%d,-,-,%s,%s,-,%s", mcc, mnc, earfcn, pci, r(rsrp), r(rsrq), cid, t, lteBand(earfcn)), fmt.Sprintf("L%d-%d", earfcn, pci))
			p = p[10:]
		}
	}

	// LTE inter-frequency (0x14)
	if c, ok := tlvs[0x14]; ok && len(c) >= 2 {
		nf := int(c[1])
		p := c[2:]
		for f := 0; f < nf && len(p) >= 6; f++ {
			earfcn := le16(p[0:2])
			nc := int(p[5])
			p = p[6:]
			for i := 0; i < nc && len(p) >= 10; i++ {
				pci, rsrq, rsrp := le16(p[0:2]), s16(p[2:4]), s16(p[4:6])
				add(fmt.Sprintf("+QSCAN: \"LTE\",%s,%s,%d,%d,%d,%d,-,-,-,-,-,%s", mcc, mnc, earfcn, pci, r(rsrp), r(rsrq), lteBand(earfcn)), fmt.Sprintf("L%d-%d", earfcn, pci))
				p = p[10:]
			}
		}
	}
	if len(out) == 0 {
		return "OK"
	}
	return strings.Join(out, "\n") + "\n\nOK"
}

// lteTimeAdvance answers Quectel's AT+QNWCFG="lte_time_advance" from QMI NAS
// "Get Cell Location Info" TLV 0x1E (LTE timing advance in microseconds,
// 0xFFFFFFFF = unavailable), converted to the 3GPP TA index the UI expects:
// one TA step is 16 Ts = 16/30.72 us, so index = us * 1.92.
// The modem fills it only while on LTE; on 5G SA it is absent ("-").
// There is no NR timing advance in QMI, so nr5g_time_advance stays ERROR.
func lteTimeAdvance() string {
	ta := "-"
	if tlvs, err := qmiRequest(3, 0x0043); err == nil {
		ta = taIndexFromTLV(tlvs[0x1E])
	}
	return "+QNWCFG: \"lte_time_advance\",1," + ta + "\n\nOK"
}

func taIndexFromTLV(v []byte) string {
	if len(v) < 4 {
		return "-"
	}
	us := binary.LittleEndian.Uint32(v)
	if us == 0xFFFFFFFF {
		return "-"
	}
	return strconv.Itoa(int(float64(us)*1.92 + 0.5))
}
