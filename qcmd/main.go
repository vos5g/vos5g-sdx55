// qcmd: Quectel-AT compatibility layer for the Compal RXM-G1 / Tri Cascade SG500M2-X (SDX55).
// QManager calls `qcmd "<AT command>"`; we answer in Quectel format using cricli and Compal AT (atcli).
// Always prints something ending in OK or ERROR, so QManager never falls back to raw serial or mock data.
package main

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const cacheDir = "/tmp/qcmd-cache"
const defaultsFile = "/data/vosclean/state/bands.default"

func main() {
	if len(os.Args) < 2 {
		fmt.Println("ERROR")
		return
	}
	if os.Args[1] == "sms_tool" { // multi-call: qcmd sms_tool ...
		smsTool(os.Args[2:])
		return
	}
	cmd := strings.TrimSpace(strings.Join(os.Args[1:], " "))
	out := handle(cmd)
	audit(cmd, out)
	out = strings.TrimRight(out, "\r\n ")
	if out == "" {
		out = "ERROR"
	}
	fmt.Print(strings.ReplaceAll(out, "\n", "\r\n") + "\r\n")
}

// ---------- helpers ----------

// audit records every command that changes modem state (not queries) to persistent storage,
// with the calling process, so unexpected actions (e.g. reboots) can be traced afterwards.
func isWrite(cmd string) bool {
	u := strings.ToUpper(cmd)
	if !strings.Contains(u, "=") || strings.HasSuffix(u, "?") || strings.HasSuffix(u, "=?") {
		return false
	}
	if regexp.MustCompile(`^AT\+[A-Z0-9]+="[A-Z0-9_/]+"$`).MatchString(u) || // AT+X="name" (no value) is a query
		strings.HasPrefix(u, `AT+QENG=`) ||
		u == "AT+CGPADDR=1" || u == "AT+CGCONTRDP=1" || u == "AT+EGMR=0,0" || u == "AT+CMGF=1" ||
		strings.HasPrefix(u, `AT+CPMS="ME"`) {
		return false // these are queries in practice
	}
	return true
}

func audit(cmd, out string) {
	if !isWrite(cmd) {
		return
	}
	parent, _ := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", os.Getppid()))
	res := strings.ReplaceAll(strings.TrimSpace(out), "\n", " | ")
	if len(res) > 120 {
		res = res[:120]
	}
	line := fmt.Sprintf("%s ppid=%d (%s) cmd=%q result=%q\n", time.Now().UTC().Format("2006-01-02 15:04:05"), os.Getppid(), strings.ReplaceAll(string(parent), "\x00", " "), cmd, res)
	p := "/data/vosclean/log/qcmd-writes.log"
	if st, err := os.Stat(p); err == nil && st.Size() > 200000 {
		_ = os.Rename(p, p+".1")
	}
	if f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
		_, _ = f.WriteString(line)
		f.Close()
	}
}

func lock(name string) func() {
	_ = os.MkdirAll(cacheDir, 0755)
	f, err := os.OpenFile(filepath.Join(cacheDir, name+".lock"), os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return func() {}
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }
}

func runTimeout(d time.Duration, name string, args ...string) string {
	c := exec.Command(name, args...)
	done := make(chan struct{})
	var out []byte
	go func() { out, _ = c.CombinedOutput(); close(done) }()
	select {
	case <-done:
	case <-time.After(d):
		if c.Process != nil {
			_ = c.Process.Kill()
		}
		<-done
	}
	return string(out)
}

// cached runs a read-only query with a short TTL cache so one poll cycle doesn't hammer the modem.
func cached(ttl time.Duration, name string, args ...string) string {
	key := name + " " + strings.Join(args, " ")
	h := sha1.Sum([]byte(key))
	p := filepath.Join(cacheDir, hex.EncodeToString(h[:8]))
	if st, err := os.Stat(p); err == nil && time.Since(st.ModTime()) < ttl {
		if b, err := os.ReadFile(p); err == nil {
			return string(b)
		}
	}
	unlock := lock("modem")
	out := runTimeout(12*time.Second, name, args...)
	unlock()
	_ = os.MkdirAll(cacheDir, 0755)
	tmp := p + ".tmp"
	if os.WriteFile(tmp, []byte(out), 0644) == nil {
		_ = os.Rename(tmp, p)
	}
	return out
}

func cri(args ...string) string { return cached(3*time.Second, "cricli", args...) }

// atcli has no locking and can return a stale reply left on the shared channel.
// A correct reply starts with the echo of our command; retry (which drains the stale one) until it does.
func atValidated(c string) string {
	for i := 0; i < 4; i++ {
		out := runTimeout(10*time.Second, "atcli", c)
		t := strings.TrimLeft(out, "\r\n ")
		first := strings.TrimSpace(strings.SplitN(t, "\n", 2)[0])
		if strings.EqualFold(first, c) {
			body := ""
			if parts := strings.SplitN(t, "\n", 2); len(parts) == 2 {
				body = parts[1]
			}
			return body
		}
		time.Sleep(150 * time.Millisecond)
	}
	return "ERROR"
}

func at(c string) string {
	h := sha1.Sum([]byte("atcli " + c))
	p := filepath.Join(cacheDir, hex.EncodeToString(h[:8]))
	if st, err := os.Stat(p); err == nil && time.Since(st.ModTime()) < 3*time.Second {
		if b, err := os.ReadFile(p); err == nil {
			return string(b)
		}
	}
	unlock := lock("modem")
	out := atValidated(c)
	unlock()
	_ = os.MkdirAll(cacheDir, 0755)
	if os.WriteFile(p+".tmp", []byte(out), 0644) == nil {
		_ = os.Rename(p+".tmp", p)
	}
	return out
}

// uncached write
func criSet(args ...string) string {
	unlock := lock("modem")
	defer unlock()
	_ = os.RemoveAll(cacheDir + "/") // invalidate cache after a change
	return runTimeout(15*time.Second, "cricli", args...)
}
func atRaw(c string) string {
	unlock := lock("modem")
	defer unlock()
	return atValidated(c)
}

func criOK(out string) bool { return strings.Contains(out, "rc: 0, error: 0") }
func okErr(b bool) string {
	if b {
		return "OK"
	}
	return "ERROR"
}

func field(s, re string) string {
	m := regexp.MustCompile(re).FindStringSubmatch(s)
	if len(m) > 1 {
		return strings.TrimSpace(m[1])
	}
	return ""
}

// section returns the text after a "---------- X Info" header up to the next header
func section(s, name string) string {
	i := strings.Index(s, name)
	if i < 0 {
		return ""
	}
	rest := s[i+len(name):]
	if j := strings.Index(rest, "----------"); j >= 0 {
		// skip the trailing dashes of our own header line
		rest2 := rest[j:]
		k := strings.Index(rest2, "\n")
		if k >= 0 {
			rest = rest2[k+1:]
		}
	}
	if j := strings.Index(rest, "---------- "); j >= 0 {
		rest = rest[:j]
	}
	return rest
}

func atoi(s string) int { v, _ := strconv.Atoi(strings.TrimSpace(s)); return v }

// ---------- band helpers ----------

// band n -> bit (n-1), spread over 64-bit words
func bandsToMasks(bands []int, words int) []string {
	ws := make([]*big.Int, words)
	for i := range ws {
		ws[i] = new(big.Int)
	}
	for _, b := range bands {
		if b < 1 {
			continue
		}
		w := (b - 1) / 64
		if w < words {
			ws[w].SetBit(ws[w], (b-1)%64, 1)
		}
	}
	out := make([]string, words)
	for i, w := range ws {
		out[i] = "0x" + strings.ToUpper(w.Text(16))
	}
	return out
}

func masksToBands(masks []string) []int {
	var out []int
	for wi, m := range masks {
		v, ok := new(big.Int).SetString(strings.TrimPrefix(strings.ToLower(m), "0x"), 16)
		if !ok {
			continue
		}
		for bit := 0; bit < 64; bit++ {
			if v.Bit(bit) == 1 {
				out = append(out, wi*64+bit+1)
			}
		}
	}
	return out
}

func capBands(kind string) []int {
	c := cached(60*time.Second, "cricli", "band_cap")
	re := `LTE EUTRAN Band (\d+)`
	if kind != "lte" {
		re = `NR5G Band (\d+)`
	}
	seen := map[int]bool{}
	var out []int
	for _, m := range regexp.MustCompile(re).FindAllStringSubmatch(c, -1) {
		b := atoi(m[1])
		if !seen[b] {
			seen[b] = true
			out = append(out, b)
		}
	}
	sort.Ints(out)
	return out
}

func prefMasks(kind string) []string {
	p := cri("get_pref_band")
	head := map[string]string{"lte": "LTE Band Pref:", "nsa": "NR5G NSA Band Pref:", "sa": "NR5G SA Band Pref:"}[kind]
	i := strings.Index(p, head)
	if i < 0 {
		return nil
	}
	part := p[i+len(head):]
	if j := strings.Index(part, "\n\n"); j >= 0 {
		part = part[:j]
	}
	var ms []string
	for _, m := range regexp.MustCompile(`0x[0-9A-Fa-f]+`).FindAllString(part, -1) {
		ms = append(ms, m)
	}
	return ms
}

func intersect(a, b []int) []int {
	set := map[int]bool{}
	for _, x := range b {
		set[x] = true
	}
	var out []int
	for _, x := range a {
		if set[x] {
			out = append(out, x)
		}
	}
	return out
}

func joinBands(b []int) string {
	s := make([]string, len(b))
	for i, x := range b {
		s[i] = strconv.Itoa(x)
	}
	return strings.Join(s, ":")
}

func defaultMasks(op string) []string {
	b, err := os.ReadFile(defaultsFile)
	if err != nil {
		return nil
	}
	for _, l := range strings.Split(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) >= 2 && f[0] == op {
			return f[1:]
		}
	}
	return nil
}

// ---------- serving cell ----------

type cell struct {
	rat                                        string // LTE, NR5G-SA, NR5G-NSA
	state                                      string
	mcc, mnc                                   string
	lteCell, ltePci, lteEarfcn, lteBand, lteBw string
	lteTac, lteRsrp, lteRsrq, lteRssi, lteSinr string
	nrCell, nrPci, nrTac, nrArfcn, nrBand      string
	nrBwMHz, nrRsrp, nrRsrq, nrSinr, nrScs     string
}

func readCell() cell {
	var c cell
	rat := field(cri("rat"), `RAT: (\S+)`)
	loc := cri("cell_location")
	lte := section(loc, "LTE Info")
	nr := section(loc, "NR5G Info")
	bnr := at("AT+BNRINFO")
	bl := at("AT+BINFO")
	bandTab := cri("band")

	switch {
	case strings.Contains(rat, "NR5G_SA"):
		c.rat = "NR5G-SA"
	case strings.Contains(rat, "NR5G"):
		c.rat = "NR5G-NSA"
	case strings.Contains(rat, "LTE"):
		c.rat = "LTE"
	default:
		c.rat = ""
	}
	if c.rat == "LTE" && !strings.Contains(bnr, "not available") && strings.Contains(bnr, "NR BAND") {
		c.rat = "NR5G-NSA"
	}

	reg := cri("get_registration_state")
	rrc := field(bnr, `RRC STATE:(\S+)`) + field(bl, `RRC STATE:(\S+)`)
	switch {
	case !strings.Contains(reg, "Registered"):
		c.state = "SEARCH"
	case strings.Contains(rrc, "CONNECTED"):
		c.state = "CONNECT"
	default:
		c.state = "NOCONN"
	}

	if c.rat == "NR5G-SA" {
		c.mcc, c.mnc = field(nr, `mcc: (\d+)`), field(nr, `mnc: (\d+)`)
	} else {
		c.mcc, c.mnc = field(lte, `mcc: (\d+)`), field(lte, `mnc: (\d+)`)
	}

	// LTE
	if gid := field(lte, `global cell id: (\d+)`); gid != "" && gid != "0" {
		v, _ := strconv.ParseInt(gid, 10, 64)
		c.lteCell = strings.ToUpper(strconv.FormatInt(v, 16))
	}
	c.ltePci = field(bl, `physical cell ID (\d+)`)
	c.lteEarfcn = field(bl, `EARFCN (\d+)`)
	c.lteBand = field(bl, `BAND (\d+)`)
	c.lteBw = field(bl, `dl_bandwidth (\d+)`)
	if t := field(bl, `TAC (\d+)`); t != "" {
		c.lteTac = strings.ToUpper(strconv.FormatInt(int64(atoi(t)), 16))
	}
	c.lteRsrp = field(bl, `RSRP (-?\d+) dBm`)
	c.lteRsrq = field(bl, `RSRQ (-?\d+) dB`)
	c.lteSinr = field(bl, `SINR (-?\d+) dB`)
	c.lteRssi = field(lte, `rssi:(-?\d+)`)
	if !strings.Contains(bl, "PCC INFO") || strings.Contains(bl, "<LTE PCC INFO>:<INVALID>") {
		c.ltePci, c.lteEarfcn, c.lteBand, c.lteRsrp, c.lteRsrq, c.lteSinr, c.lteTac = "", "", "", "", "", "", ""
		if v := field(lte, `pci: (\d+)`); v != "" && v != "0" {
			c.ltePci = v
			c.lteEarfcn = field(lte, `afcn: (\d+)`)
			c.lteBand = field(bandTab, `LTE Band (\d+)`)
			c.lteRsrp = field(lte, `rsrp:(-?\d+)`)
			c.lteRsrq = field(lte, `rsrq:(-?\d+)`)
			if t := field(lte, `tac: (\d+)`); t != "" && t != "0" {
				c.lteTac = strings.ToUpper(strconv.FormatInt(int64(atoi(t)), 16))
			}
		}
	}
	if c.lteRssi == "0" {
		c.lteRssi = ""
	}

	// NR
	c.nrPci = field(nr, `pci: (\d+)`)
	c.nrArfcn = field(nr, `afrcn: (\d+)`)
	c.nrRsrp = field(nr, `rsrp:(-?\d+)`)
	c.nrRsrq = field(nr, `rsrq:(-?\d+)`)
	c.nrSinr = field(nr, `snr:(-?\d+)`)
	c.nrBand = field(bandTab, `NR5G Band (\d+)`)
	for _, p := range []*string{&c.nrPci, &c.nrArfcn, &c.nrRsrp, &c.nrRsrq, &c.nrSinr} {
		if *p == "0" {
			*p = ""
		}
	}
	if c.nrBand == "" && !strings.Contains(bnr, "not available") {
		c.nrBand = field(bnr, `NR BAND:(\d+)`)
	}
	if gid := field(nr, `global cell id: (\d+)`); gid != "" && gid != "0" {
		v, _ := strconv.ParseInt(gid, 10, 64)
		c.nrCell = strings.ToUpper(strconv.FormatInt(v, 16))
	}
	if t := field(nr, `tac: 0x([0-9A-Fa-f]+)`); t != "" && t != "0" {
		c.nrTac = strings.ToUpper(t)
	}
	// bandwidth from cricli band table ("NR5G 80 MHz")
	c.nrBwMHz = field(bandTab, `NR5G (\d+) MHz`)
	if c.nrBwMHz == "" {
		c.nrBwMHz = field(bnr, `DL_bandwidth:(\d+)MHz`)
	}
	c.nrScs = "1" // 30 kHz: all UK/EU FR1 TDD carriers
	return c
}

func nrBwCode(mhz string) string { // Quectel <NR_DL_bandwidth> code
	m := map[string]string{"5": "0", "10": "1", "15": "2", "20": "3", "25": "4", "30": "5", "40": "6", "50": "7", "60": "8", "70": "9", "80": "10", "90": "11", "100": "12"}
	if v, ok := m[mhz]; ok {
		return v
	}
	return "-"
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func qeng() string {
	c := readCell()
	var b strings.Builder
	switch c.rat {
	case "NR5G-SA":
		// +QENG: "servingcell",<state>,"NR5G-SA",<duplex>,<MCC>,<MNC>,<cellID>,<PCID>,<TAC>,<ARFCN>,<band>,<NR_DL_bw>,<RSRP>,<RSRQ>,<SINR>,<scs>,<srxlev>
		fmt.Fprintf(&b, "+QENG: \"servingcell\",\"%s\",\"NR5G-SA\",\"TDD\",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,-\n",
			c.state, dash(c.mcc), dash(c.mnc), dash(c.nrCell), dash(c.nrPci), dash(c.nrTac), dash(c.nrArfcn), dash(c.nrBand), nrBwCode(c.nrBwMHz), dash(c.nrRsrp), dash(c.nrRsrq), dash(c.nrSinr), c.nrScs)
	case "LTE":
		// +QENG: "servingcell",<state>,"LTE",<is_tdd>,<MCC>,<MNC>,<cellID>,<PCID>,<earfcn>,<band>,<UL_bw>,<DL_bw>,<TAC>,<RSRP>,<RSRQ>,<RSSI>,<SINR>,<CQI>,<tx_power>,<srxlev>
		fmt.Fprintf(&b, "+QENG: \"servingcell\",\"%s\",\"LTE\",\"FDD\",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,-,-,-\n",
			c.state, dash(c.mcc), dash(c.mnc), dash(c.lteCell), dash(c.ltePci), dash(c.lteEarfcn), dash(c.lteBand), dash(c.lteBw), dash(c.lteBw), dash(c.lteTac), dash(c.lteRsrp), dash(c.lteRsrq), dash(c.lteRssi), dash(c.lteSinr))
	case "NR5G-NSA":
		fmt.Fprintf(&b, "+QENG: \"servingcell\",\"%s\"\n", c.state)
		// +QENG: "LTE",<is_tdd>,<MCC>,<MNC>,<cellID>,<PCID>,<earfcn>,<band>,<UL_bw>,<DL_bw>,<TAC>,<RSRP>,<RSRQ>,<RSSI>,<SINR>,<CQI>,<tx_power>,<srxlev>
		fmt.Fprintf(&b, "+QENG: \"LTE\",\"FDD\",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,-,-,-\n",
			dash(c.mcc), dash(c.mnc), dash(c.lteCell), dash(c.ltePci), dash(c.lteEarfcn), dash(c.lteBand), dash(c.lteBw), dash(c.lteBw), dash(c.lteTac), dash(c.lteRsrp), dash(c.lteRsrq), dash(c.lteRssi), dash(c.lteSinr))
		// +QENG: "NR5G-NSA",<MCC>,<MNC>,<PCID>,<RSRP>,<SINR>,<RSRQ>,<ARFCN>,<band>,<NR_DL_bw>,<scs>
		fmt.Fprintf(&b, "+QENG: \"NR5G-NSA\",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
			dash(c.mcc), dash(c.mnc), dash(c.nrPci), dash(c.nrRsrp), dash(c.nrSinr), dash(c.nrRsrq), dash(c.nrArfcn), dash(c.nrBand), nrBwCode(c.nrBwMHz), c.nrScs)
	default:
		fmt.Fprintf(&b, "+QENG: \"servingcell\",\"SEARCH\"\n")
	}
	b.WriteString("\nOK")
	return b.String()
}

func qcainfo() string {
	var b strings.Builder
	c := readCell()
	lteBwMHz := map[string]int{"0": 1, "1": 3, "2": 5, "3": 10, "4": 15, "5": 20}
	add := func(src, tech string) {
		for _, l := range strings.Split(src, "\n") {
			m := regexp.MustCompile(`^(PCC|SCC \d)\s+Band:(\d+) RSRP:(-?\d+) dbm(?: EARFCN:(\d+))?(?: PCI:(\d+))?`).FindStringSubmatch(strings.TrimSpace(l))
			if m == nil {
				continue
			}
			role := "SCC"
			if m[1] == "PCC" {
				role = "PCC"
			}
			if tech == "LTE" {
				earfcn, pci, bw := m[4], m[5], ""
				if role == "PCC" {
					earfcn, pci = c.lteEarfcn, c.ltePci
					if v, ok := lteBwMHz[c.lteBw]; ok {
						bw = strconv.Itoa(v * 5)
					}
				}
				fmt.Fprintf(&b, "+QCAINFO: \"%s\",%s,%s,\"LTE BAND %s\",1,%s,%s,%s,%s,%s\n", role, dash(earfcn), dash(bw), m[2], dash(pci), m[3], dash(boolStr(role == "PCC", c.lteRsrq)), dash(boolStr(role == "PCC", c.lteRssi)), dash(boolStr(role == "PCC", c.lteSinr)))
			} else {
				arfcn, pci := m[4], m[5]
				rsrq := ""
				if arfcn == c.nrArfcn {
					rsrq = c.nrRsrq
				}
				fmt.Fprintf(&b, "+QCAINFO: \"%s\",%s,%s,\"NR5G BAND %s\",%s,%s,%s\n", role, dash(arfcn), nrBwCode(c.nrBwMHz), m[2], dash(pci), m[3], dash(rsrq))
			}
		}
	}
	add(at("AT+LCAINFO"), "LTE")
	nrca := at("AT+NRCAINFO")
	// In NSA, the NR leg is an SCC from Quectel's point of view
	if c.rat == "NR5G-NSA" {
		nrca = strings.Replace(nrca, "PCC ", "SCC 9", 1)
	}
	add(nrca, "NR")
	if b.Len() == 0 {
		return "ERROR"
	}
	b.WriteString("\nOK")
	return b.String()
}

func boolStr(ok bool, s string) string {
	if ok {
		return s
	}
	return ""
}

// ---------- dispatcher ----------

var reArgs = regexp.MustCompile(`"([^"]*)"|([^,]+)`)

func args(s string) []string {
	var out []string
	for _, m := range reArgs.FindAllStringSubmatch(s, -1) {
		if m[1] != "" || strings.HasPrefix(m[0], `"`) {
			out = append(out, m[1])
		} else {
			out = append(out, strings.TrimSpace(m[2]))
		}
	}
	return out
}

func handle(cmd string) string {
	u := strings.ToUpper(cmd)
	switch {
	case u == "AT" || u == "ATE0" || u == "ATE1":
		return "OK"
	case u == "ATI":
		a := at("ATI")
		return fmt.Sprintf("%s\n%s\nRevision: %s\n\nOK", dash(field(a, `Model: (.*)`)), dash(field(a, `Manufacturer: (.*)`)), dash(field(a, `Revision: (.*)`)))
	case u == "AT+CGMI" || u == "AT+GMI":
		return "+CGMI: " + field(at("ATI"), `Manufacturer: (.*)`) + "\n\nOK"
	case u == "AT+GMM" || u == "AT+CGMM":
		p := "+GMM: "
		if u == "AT+CGMM" {
			p = "+CGMM: "
		}
		return p + field(at("ATI"), `Model: (.*)`) + "\n\nOK"
	case u == "AT+CGMR" || u == "AT+GMR":
		return field(at("ATI"), `Revision: (.*)`) + "\n\nOK"
	case u == "AT+GSN" || u == "AT+CGSN" || u == "AT+CGSN=1":
		if v := field(cri("imei"), `IMEI: (\d+)`); v != "" {
			return v + "\n\nOK"
		}
		return "ERROR"
	case u == "AT+QCCID" || u == "AT+ICCID" || u == "AT+CCID":
		if v := field(cri("iccid"), `ICCID: (\w+)`); v != "" {
			p := map[string]string{"AT+QCCID": "+QCCID: ", "AT+ICCID": "+ICCID: ", "AT+CCID": "+CCID: "}[u]
			return p + v + "\n\nOK"
		}
		return "+CME ERROR: 10"
	case u == "AT+CIMI":
		if v := field(cri("imsi"), `IMSI: (\d+)`); v != "" {
			return v + "\n\nOK"
		}
		return "+CME ERROR: 10"
	case u == "AT+CNUM":
		n := field(cri("msisdn"), `Number: (\+?\d+)`)
		if n == "" {
			return "OK"
		}
		return fmt.Sprintf("+CNUM: \"\",\"%s\",145\n\nOK", n)
	case u == "AT+CPIN?":
		cs := cri("card_status")
		switch {
		case !strings.Contains(cs, "PRESENT"):
			return "+CME ERROR: 10"
		case strings.Contains(cs, "APP state: READY"):
			return "+CPIN: READY\n\nOK"
		case strings.Contains(cs, "PUK"):
			return "+CPIN: SIM PUK\n\nOK"
		default:
			return "+CPIN: SIM PIN\n\nOK"
		}
	case u == "AT+CREG?" || u == "AT+CEREG?" || u == "AT+C5GREG?":
		p := "+" + strings.TrimSuffix(strings.TrimPrefix(u, "AT+"), "?")
		st := "0"
		if strings.Contains(cri("get_registration_state"), "Registered") {
			st = "1"
			if strings.Contains(cri("roaming"), "Roam") {
				st = "5"
			}
		}
		return fmt.Sprintf("%s: 0,%s\n\nOK", p, st)
	case u == "AT+COPS?":
		c := readCell()
		op := strings.TrimSpace(strings.Split(strings.TrimSpace(strings.Replace(cri("operator"), "rc: 0, error: 0", "", 1)), "(")[0])
		plmn := field(cri("operator"), `\((\d+)\)`)
		if op == "" {
			op = map[string]string{"23410": "O2 - UK", "23415": "Vodafone UK", "23420": "3 UK", "23430": "EE", "23433": "EE"}[plmn]
		}
		if op == "" {
			op = plmn
		}
		if op == "" {
			return "+COPS: 0\n\nOK"
		}
		act := "7"
		if c.rat == "NR5G-SA" {
			act = "12"
		} else if c.rat == "NR5G-NSA" {
			act = "13"
		}
		return fmt.Sprintf("+COPS: 0,0,\"%s\",%s\n\nOK", op, act)
	case strings.HasPrefix(u, "AT+COPS="):
		return "OK" // network re-selection is left to the modem
	case u == "AT+CSQ":
		r := atoi(field(cri("cell_location"), `rssi:(-?\d+)`))
		if r >= 0 || r < -113 {
			return "+CSQ: 99,99\n\nOK"
		}
		return fmt.Sprintf("+CSQ: %d,99\n\nOK", (r+113)/2)
	case u == "AT+CESQ":
		return strings.TrimSpace(at("AT+CESQ"))
	case u == "AT+CGPADDR=1" || u == "AT+CGPADDR":
		ip := field(cri("wwan_config"), `IPV4 IP address: (\S+)`)
		if ip == "" {
			return "OK"
		}
		return fmt.Sprintf("+CGPADDR: 1,\"%s\"\n\nOK", ip)
	case u == "AT+CGCONTRDP=1" || u == "AT+CGCONTRDP":
		w := cri("wwan_config")
		apn := profileAPN()
		return fmt.Sprintf("+CGCONTRDP: 1,5,\"%s\",\"%s\",\"\",\"%s\",\"%s\"\n\nOK", apn, field(w, `IPV4 IP address: (\S+)`), field(w, `IPV4 Primary DNS: (\S+)`), field(w, `IPV4 Secondary DNS: (\S+)`))
	case u == "AT+CGDCONT?":
		return cgdcont()
	case strings.HasPrefix(u, "AT+CGDCONT="):
		return setCgdcont(cmd)
	case strings.HasPrefix(u, "AT+CGACT"):
		return "OK"
	case u == `AT+QENG="SERVINGCELL"`:
		return qeng()
	case strings.HasPrefix(u, `AT+QENG="NEIGHBOURCELL"`):
		return "OK"
	case u == "AT+QCAINFO":
		return qcainfo()
	case strings.HasPrefix(u, "AT+QSCAN"):
		return cellScan()
	case u == "AT+QRSRP":
		return qrsrp()
	case u == "AT+QTEMP":
		return qtemp()
	case u == "AT+QUIMSLOT?":
		return "+QUIMSLOT: 1\n\nOK"
	case strings.HasPrefix(u, "AT+QUIMSLOT="):
		return okErr(strings.TrimSpace(strings.TrimPrefix(u, "AT+QUIMSLOT=")) == "1")
	case strings.HasPrefix(u, "AT+QNWPREFCFG="):
		return qnwprefcfg(cmd)
	case u == "AT+CNMP?":
		return "+CNMP: " + map[string]string{"AUTO": "0", "LTE": "2", "NR5G": "9", "LTE:NR5G": "13"}[modePref()] + "\n\nOK"
	case strings.HasPrefix(u, "AT+CNMP="):
		v := map[string]string{"0": "88", "2": "16", "9": "64", "13": "80"}[strings.TrimPrefix(u, "AT+CNMP=")]
		if v == "" {
			return "ERROR"
		}
		return okErr(criOK(criSet("set_pref_rat", v)))
	case strings.HasPrefix(u, `AT+QNWLOCK="COMMON/4G"`):
		return lock4g(cmd)
	case strings.HasPrefix(u, `AT+QNWLOCK="COMMON/5G"`):
		return lock5g(cmd)
	case strings.HasPrefix(u, `AT+QNWCFG="LTE_EARFCN_LOCK"`) && !strings.Contains(u, `",`):
		return "+QNWCFG: \"lte_earfcn_lock\",0\n\nOK"
	case strings.HasPrefix(u, `AT+QNWCFG="NR5G_EARFCN_LOCK"`):
		return nrEarfcnLock(cmd)
	case strings.HasPrefix(u, "AT+CFUN?"):
		if strings.Contains(cri("op_mode"), "Online") {
			return "+CFUN: 1\n\nOK"
		}
		return "+CFUN: 4\n\nOK"
	case u == "AT+CFUN=0" || u == "AT+CFUN=4":
		return okErr(criOK(criSet("set_op_mode", "1")))
	case u == "AT+CFUN=1":
		return okErr(criOK(criSet("set_op_mode", "0")))
	case u == "AT+CFUN=1,1":
		_ = exec.Command("/bin/sh", "-c", "(sleep 3; sync; systemctl reboot) >/dev/null 2>&1 &").Start()
		return "OK"
	case strings.HasPrefix(u, "AT+CPMS"):
		total := field(cri("sms_capacity", "1"), `MAX storage size: (\d+)`)
		free := field(cri("sms_capacity", "1"), `Free storage size: (\d+)`)
		used := atoi(total) - atoi(free)
		return fmt.Sprintf("+CPMS: %d,%s,%d,%s,%d,%s\n\nOK", used, dash(total), used, dash(total), used, dash(total))
	case strings.HasPrefix(u, "AT+CMGF"):
		return "OK"
	// Not available on this module, or deliberately blocked
	case strings.HasPrefix(u, "AT+EGMR"), strings.HasPrefix(u, "AT+CRSM"),
		strings.HasPrefix(u, "AT+QMBNCFG"), strings.HasPrefix(u, "AT+QNWCFG"), strings.HasPrefix(u, "AT+CMGS"),
		strings.Contains(u, "CEIFACRESET"), strings.Contains(u, "FWNV"), strings.HasPrefix(u, "AT+USBCOMP="):
		return "ERROR"
	}
	// Anything else: pass through to the Compal AT handler (AT terminal)
	if !regexp.MustCompile(`^AT[A-Za-z0-9+$^&?=,."_ :/-]{0,160}$`).MatchString(cmd) {
		return "ERROR"
	}
	return strings.TrimSpace(atRaw(cmd))
}

func profileAPN() string {
	p := cri("get_profile")
	for _, l := range strings.Split(p, "\n") {
		f := strings.Fields(l)
		if len(f) >= 2 && (f[0] == "01" || f[0] == "1") {
			for _, x := range f[1:] {
				if strings.Contains(x, ".") || (len(x) > 2 && !regexp.MustCompile(`^(IPV4V6|IPV4|IPV6|NONE|PAP|CHAP)$`).MatchString(x)) {
					return strings.ToLower(x)
				}
			}
		}
	}
	return ""
}

func profilePDP() string {
	p := cri("get_profile")
	for _, t := range []string{"IPV4V6", "IPV6", "IPV4"} {
		if strings.Contains(p, t) {
			return t
		}
	}
	return "IPV4V6"
}

func cgdcont() string {
	apn := profileAPN()
	if apn == "" {
		return "OK"
	}
	return fmt.Sprintf("+CGDCONT: 1,\"%s\",\"%s\",\"\",0,0,0,0\n\nOK", profilePDP(), apn)
}

func setCgdcont(cmd string) string {
	a := args(cmd[strings.Index(cmd, "=")+1:])
	if len(a) < 3 || strings.TrimSpace(a[0]) != "1" {
		return "ERROR" // only profile 1 is managed here
	}
	pdp := map[string]string{"IP": "0", "IPV4": "0", "IPV6": "2", "IPV4V6": "3"}[strings.ToUpper(a[1])]
	apn := a[2]
	if pdp == "" || !regexp.MustCompile(`^[A-Za-z0-9._-]{1,62}$`).MatchString(apn) {
		return "ERROR"
	}
	return okErr(criOK(criSet("set_profile", "1", "", apn, "", "", pdp, "0")))
}

func qrsrp() string {
	var b strings.Builder
	line := func(src, tech string) {
		vals := []string{"0", "0", "0", "0"}
		n := 0
		for _, m := range regexp.MustCompile(`RX(\d)[: ]+power: -?\d+ dBm.*?rsrp: (-?\d+) dBm`).FindAllStringSubmatch(src, -1) {
			i := atoi(m[1])
			if i < 4 {
				vals[i] = m[2]
				n++
			}
		}
		for _, m := range regexp.MustCompile(`RX(\d) rsrp: (-?\d+) dBm`).FindAllStringSubmatch(src, -1) {
			i := atoi(m[1])
			if i < 4 {
				vals[i] = m[2]
				n++
			}
		}
		if n > 0 {
			fmt.Fprintf(&b, "+QRSRP: %s,%s,%s,%s,%s\n", vals[0], vals[1], vals[2], vals[3], tech)
		}
	}
	bl := at("AT+BINFO")
	if strings.Contains(bl, "PCC INFO") {
		line(bl, "LTE")
	}
	bnr := at("AT+BNRINFO")
	if !strings.Contains(bnr, "not available") {
		tech := "NR5G"
		if readCell().rat == "NR5G-SA" {
			tech = "NR5G-SA"
		}
		line(bnr, tech)
	}
	if b.Len() == 0 {
		return "ERROR"
	}
	b.WriteString("\nOK")
	return b.String()
}

func qtemp() string {
	zones, _ := filepath.Glob("/sys/class/thermal/thermal_zone*")
	want := map[string]bool{"mdm-core-usr": true, "cpu0-a7-usr": true, "mdm-5g-usr": true, "mdm-q6-usr": true, "ipa-usr": true, "pa-therm1-usr": true, "sdx-case-therm-usr": true, "xo-therm-usr": true}
	var b strings.Builder
	for _, z := range zones {
		t, _ := os.ReadFile(z + "/type")
		v, _ := os.ReadFile(z + "/temp")
		name := strings.TrimSpace(string(t))
		if !want[name] {
			continue
		}
		mv, err := strconv.Atoi(strings.TrimSpace(string(v)))
		if err != nil {
			continue
		}
		fmt.Fprintf(&b, "+QTEMP: \"%s\",\"%d\"\n", name, mv/1000)
	}
	if b.Len() == 0 {
		return "ERROR"
	}
	b.WriteString("\nOK")
	return b.String()
}

func modePref() string {
	r := cri("get_pref_rat")
	hasL, hasN, hasU := strings.Contains(r, "LTE"), strings.Contains(r, "NR5G"), strings.Contains(r, "UMTS")
	switch {
	case hasL && hasN && hasU:
		return "AUTO"
	case hasL && hasN:
		return "LTE:NR5G"
	case hasN && !hasL:
		return "NR5G"
	case hasL && hasU:
		return "WCDMA:LTE"
	case hasL:
		return "LTE"
	}
	return "AUTO"
}

func qnwprefcfg(cmd string) string {
	a := args(cmd[strings.Index(cmd, "=")+1:])
	if len(a) == 0 {
		return "ERROR"
	}
	key := strings.ToLower(a[0])
	set := len(a) >= 2
	kind := map[string]string{"lte_band": "lte", "nsa_nr5g_band": "nsa", "nr5g_band": "sa"}[key]
	op := map[string]string{"lte": "2", "nsa": "3", "sa": "4"}[kind]
	switch {
	case key == "ue_capability_band":
		nr := joinBands(capBands("nr"))
		return fmt.Sprintf("+QNWPREFCFG: \"gw_band\",1:2:4:5:8:19\n+QNWPREFCFG: \"lte_band\",%s\n+QNWPREFCFG: \"nsa_nr5g_band\",%s\n+QNWPREFCFG: \"nr5g_band\",%s\n\nOK", joinBands(capBands("lte")), nr, nr)
	case kind != "" && !set:
		capK := "nr"
		if kind == "lte" {
			capK = "lte"
		}
		return fmt.Sprintf("+QNWPREFCFG: \"%s\",%s\n\nOK", key, joinBands(intersect(capBands(capK), masksToBands(prefMasks(kind)))))
	case kind != "" && set:
		val := strings.Join(a[1:], ",")
		var masks []string
		if strings.EqualFold(val, "all") || val == "0" {
			masks = defaultMasks(op)
			if masks == nil {
				return "ERROR"
			}
		} else {
			if !regexp.MustCompile(`^[0-9]+(:[0-9]+)*$`).MatchString(val) {
				return "ERROR"
			}
			var bands []int
			for _, s := range strings.Split(val, ":") {
				bands = append(bands, atoi(s))
			}
			capK := "nr"
			if kind == "lte" {
				capK = "lte"
			}
			bands = intersect(bands, capBands(capK))
			if len(bands) == 0 {
				return "ERROR" // never allow an empty band set
			}
			masks = bandsToMasks(bands, 5)
		}
		if kind == "lte" {
			return okErr(criOK(criSet("set_pref_band", "2", masks[0])))
		}
		for len(masks) < 5 {
			masks = append(masks, "0x0")
		}
		return okErr(criOK(criSet(append([]string{"set_pref_band", op}, masks[:5]...)...)))
	case key == "nrdc_nr5g_band":
		return "ERROR"
	case key == "mode_pref" && !set:
		return fmt.Sprintf("+QNWPREFCFG: \"mode_pref\",%s\n\nOK", modePref())
	case key == "mode_pref" && set:
		v := map[string]string{"AUTO": "88", "LTE:NR5G": "80", "NR5G:LTE": "80", "NR5G": "64", "LTE": "16", "WCDMA:LTE": "24", "LTE:WCDMA": "24", "WCDMA": "8"}[strings.ToUpper(a[1])]
		if v == "" {
			return "ERROR"
		}
		return okErr(criOK(criSet("set_pref_rat", v)))
	case key == "nr5g_disable_mode" && !set:
		return "+QNWPREFCFG: \"nr5g_disable_mode\",0\n\nOK"
	}
	return "ERROR"
}

func lock4g(cmd string) string {
	a := args(cmd[strings.Index(cmd, "=")+1:])
	if len(a) == 1 { // query: table rows "ID  PCI  Freq"
		cfg := cri("get_cell_config")
		pairs := regexp.MustCompile(`(?m)^\s*\d+\s+(\d+)\s+(\d+)\s*$`).FindAllStringSubmatch(cfg, -1)
		if len(pairs) == 0 {
			return "+QNWLOCK: \"common/4g\",0\n\nOK"
		}
		s := fmt.Sprintf("+QNWLOCK: \"common/4g\",%d", len(pairs))
		for _, p := range pairs {
			s += "," + p[2] + "," + p[1] // earfcn,pci
		}
		return s + "\n\nOK"
	}
	n := atoi(a[1])
	if n == 0 {
		return okErr(criOK(criSet("set_cell_config")))
	}
	if n < 0 || n > 10 || len(a) < 2+2*n {
		return "ERROR"
	}
	argv := []string{"set_cell_config"}
	for i := 0; i < n; i++ {
		earfcn, pci := a[2+2*i], a[3+2*i]
		if atoi(pci) < 0 || atoi(pci) > 503 || atoi(earfcn) <= 0 {
			return "ERROR"
		}
		argv = append(argv, strconv.Itoa(atoi(pci)), strconv.Itoa(atoi(earfcn)))
	}
	return okErr(criOK(criSet(argv...)))
}

func lock5g(cmd string) string {
	a := args(cmd[strings.Index(cmd, "=")+1:])
	if len(a) == 1 { // query
		cfg := cri("get_nr5g_cell_config")
		if strings.Contains(cfg, "UNLOCK") || !strings.Contains(cfg, "type") {
			return "+QNWLOCK: \"common/5g\",0\n\nOK"
		}
		pci, arfcn := field(cfg, `pci: (\d+)`), field(cfg, `afrcn: (\d+)`)
		scs := field(cfg, `subcarrier spacing: (\d+) KHz`)
		return fmt.Sprintf("+QNWLOCK: \"common/5g\",%s,%s,%s,%s\n\nOK", dash(pci), dash(arfcn), dash(scs), dash(field(cfg, `>>> NR5G Band\s+(\d+)`)))
	}
	if len(a) == 2 && atoi(a[1]) == 0 {
		return okErr(criOK(criSet("set_nr5g_cell_config", "2")))
	}
	if len(a) < 5 {
		return "ERROR"
	}
	pci, arfcn, scsK, band := atoi(a[1]), atoi(a[2]), atoi(a[3]), atoi(a[4])
	scs := map[int]string{15: "0", 30: "1", 60: "2", 120: "3", 240: "4", 0: "0", 1: "1", 2: "2", 3: "3"}[scsK]
	if pci < 0 || pci > 1007 || arfcn <= 0 || band <= 0 || band > 512 || scs == "" {
		return "ERROR"
	}
	argv := []string{"set_nr5g_cell_config", "0", strconv.Itoa(pci), strconv.Itoa(arfcn), scs}
	w := (band - 1) / 64
	for i := 0; i < 8; i++ {
		if i == w {
			argv = append(argv, new(big.Int).Lsh(big.NewInt(1), uint((band-1)%64)).String())
		} else {
			argv = append(argv, "0")
		}
	}
	return okErr(criOK(criSet(argv...)))
}

// ---------- sms_tool shim (status | recv | send <to> <msg> | delete <idx|all>) ----------

type sms struct {
	idx, store          int
	date, from, content string
}

func listSMS() []sms {
	var out []sms
	for _, st := range []int{1, 0} {
		raw := runTimeout(12*time.Second, "cricli", "get_msg_list", strconv.Itoa(st))
		hdr := false
		for _, l := range strings.Split(raw, "\n") {
			if strings.HasPrefix(strings.TrimSpace(l), "ID") && strings.Contains(l, "Content") {
				hdr = true
				continue
			}
			if !hdr || strings.TrimSpace(l) == "" || strings.HasPrefix(l, "rc:") {
				continue
			}
			if !regexp.MustCompile(`^\s*\d+\s`).MatchString(l) {
				continue // separators / blank rows
			}
			f := regexp.MustCompile(`\s{2,}`).Split(strings.TrimSpace(l), 5)
			if len(f) < 4 {
				continue
			}
			m := sms{idx: atoi(f[0]), store: st}
			if len(f) == 5 {
				m.date, m.from, m.content = f[2], f[3], f[4]
			} else {
				m.date, m.from = f[1], f[2]
				m.content = f[3]
			}
			out = append(out, m)
		}
	}
	return out
}

func smsTool(a []string) {
	if len(a) == 0 {
		fmt.Println("usage: sms_tool status|recv|send|delete")
		os.Exit(1)
	}
	switch a[0] {
	case "status":
		c := runTimeout(12*time.Second, "cricli", "sms_capacity", "1")
		total, free := atoi(field(c, `MAX storage size: (\d+)`)), atoi(field(c, `Free storage size: (\d+)`))
		fmt.Printf("Storage type: ME, used: %d, total: %d\n", total-free, total)
	case "recv":
		for _, m := range listSMS() {
			fmt.Printf("MSG: %d\nFrom: %s\nDate/Time: %s\n%s\n\n", m.store*1000+m.idx, m.from, m.date, m.content)
		}
	case "send":
		if len(a) < 3 || !regexp.MustCompile(`^\+?[0-9]{3,16}$`).MatchString(a[1]) {
			fmt.Println("bad number")
			os.Exit(1)
		}
		msg := strings.Join(a[2:], " ")
		out := runTimeout(30*time.Second, "cricli", "send_sms", a[1], msg)
		if !criOK(out) && strings.Contains(runTimeout(10*time.Second, "cricli", "rat"), "NR5G_SA") {
			// O2 (and others) can't carry SMS for this module in 5G SA: send over LTE, then restore.
			prev := map[string]string{"AUTO": "88", "LTE:NR5G": "80", "NR5G": "64", "LTE": "16", "WCDMA:LTE": "24"}[modePref()]
			if prev == "" {
				prev = "88"
			}
			runTimeout(10*time.Second, "cricli", "set_pref_rat", "16")
			for i := 0; i < 20; i++ {
				time.Sleep(2 * time.Second)
				if strings.Contains(runTimeout(10*time.Second, "cricli", "attach_state"), "CS State: Attached") {
					break
				}
			}
			out = runTimeout(40*time.Second, "cricli", "send_sms", a[1], msg)
			runTimeout(10*time.Second, "cricli", "set_pref_rat", prev)
		}
		if !criOK(out) {
			fmt.Print(out)
			os.Exit(1)
		}
	case "delete":
		if len(a) < 2 {
			os.Exit(1)
		}
		var targets []sms
		if a[1] == "all" {
			targets = listSMS()
		} else {
			v := atoi(a[1])
			targets = []sms{{idx: v % 1000, store: v / 1000}}
		}
		for _, m := range targets {
			runTimeout(12*time.Second, "cricli", "del_sms", strconv.Itoa(m.store), strconv.Itoa(m.idx))
		}
	}
}

// 5G frequency lock: AT+QNWCFG="nr5g_earfcn_lock",1,<arfcn>,<scs>[,<arfcn>,<scs>...] | ,0 | query.
// Maps to cricli set_nr5g_cell_config type 1 (ARFCN list). Shares the modem's single NR lock
// slot with the 5G cell lock, so setting one replaces the other.
func nrEarfcnLock(cmd string) string {
	a := args(cmd[strings.Index(cmd, "=")+1:])
	if len(a) == 1 {
		cfg := cri("get_nr5g_cell_config")
		if !strings.Contains(strings.ToLower(cfg), "afrcn list") && !strings.Contains(strings.ToLower(cfg), "arfcn list") {
			return "+QNWCFG: \"nr5g_earfcn_lock\",0\n\nOK"
		}
		out := "+QNWCFG: \"nr5g_earfcn_lock\",1"
		for _, m := range regexp.MustCompile(`(?m)^\s*(\d+)\s+(\d+) KHz`).FindAllStringSubmatch(cfg, -1) {
			out += "," + m[1] + "," + m[2]
		}
		return out + "\n\nOK"
	}
	if atoi(a[1]) == 0 {
		return okErr(criOK(criSet("set_nr5g_cell_config", "2")))
	}
	rest := a[2:]
	if len(rest) == 0 || len(rest)%2 != 0 || len(rest) > 64 {
		return "ERROR"
	}
	argv := []string{"set_nr5g_cell_config", "1"}
	for i := 0; i < len(rest); i += 2 {
		arfcn, scsK := atoi(rest[i]), atoi(rest[i+1])
		scs := map[int]string{15: "0", 30: "1", 60: "2", 120: "3", 240: "4"}[scsK]
		if arfcn <= 0 || arfcn > 3279165 || scs == "" {
			return "ERROR"
		}
		argv = append(argv, strconv.Itoa(arfcn), scs)
	}
	return okErr(criOK(criSet(argv...)))
}
