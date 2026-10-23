package main

import "testing"

func TestMasks(t *testing.T) {
	m := bandsToMasks([]int{1, 3, 7, 20, 28, 78}, 5)
	if m[0] != "0x8080045" || m[1] != "0x2000" {
		t.Fatalf("masks %v", m)
	}
	b := masksToBands([]string{"0x00008120090808D7", "0x7042"})
	want := []int{1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 38, 41, 48, 66, 71, 77, 78, 79}
	if len(b) != len(want) {
		t.Fatalf("bands %v", b)
	}
	for i := range b {
		if b[i] != want[i] {
			t.Fatalf("bands %v", b)
		}
	}
}

func TestArgs(t *testing.T) {
	a := args(`"lte_band",1:3:7`)
	if len(a) != 2 || a[0] != "lte_band" || a[1] != "1:3:7" {
		t.Fatalf("%q", a)
	}
	a = args(`"common/5g",101,648768,30,78`)
	if len(a) != 5 || a[4] != "78" {
		t.Fatalf("%q", a)
	}
}

func TestAuditIsQuery(t *testing.T) {
	// queries must not be written to flash; writes must
	for _, q := range []string{`AT+QENG="servingcell"`, `AT+QNWPREFCFG="lte_band"`, `AT+QNWLOCK="common/5g"`, "AT+CGPADDR=1", "AT+CPIN?", "AT+COPS?"} {
		if isWrite(q) {
			t.Errorf("query treated as write: %s", q)
		}
	}
	for _, w := range []string{`AT+QNWPREFCFG="lte_band",1:3`, `AT+QNWLOCK="common/5g",0`, "AT+CFUN=1,1", "AT+COPS=2", `AT+CGDCONT=1,"IPV4V6","x"`} {
		if !isWrite(w) {
			t.Errorf("write not audited: %s", w)
		}
	}
}

func TestLteBandAndPLMN(t *testing.T) {
	if lteBand(223) != "1" || lteBand(1474) != "3" || lteBand(6300) != "20" || lteBand(3050) != "7" {
		t.Fatal("lte band map")
	}
	mcc, mnc := bcdPLMN([]byte{0x32, 0xF4, 0x01})
	if mcc != "234" || mnc != "10" {
		t.Fatalf("plmn %s %s", mcc, mnc)
	}
}

func TestTAIndexFromTLV(t *testing.T) {
	le := func(v uint32) []byte { return []byte{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)} }
	for _, c := range []struct {
		in   []byte
		want string
	}{
		{le(0xFFFFFFFF), "-"}, {nil, "-"}, {le(0), "0"}, {le(10), "19"}, {le(100), "192"},
	} {
		if got := taIndexFromTLV(c.in); got != c.want {
			t.Errorf("taIndexFromTLV(%v) = %s, want %s", c.in, got, c.want)
		}
	}
}

const profileHdr = "rc: 0, error: 0\n ID  Profile Name  APN           Username      Password      PDP Type      Auth Type\n --  ------------  ------------  ------------  ------------  ------------  ------------\n"

func TestParseProfile(t *testing.T) {
	cases := []struct {
		row  string
		want profile
	}{
		// real rows from the stick
		{" 01                Three.co.uk                               IPV4V6        NONE        ", profile{apn: "Three.co.uk", pdp: "IPV4V6"}},
		{" 01                Three.co.uk   qmtestuser    qmtestpass    IPV4V6        PAP         ", profile{apn: "Three.co.uk", user: "qmtestuser", pass: "qmtestpass", pdp: "IPV4V6", auth: 1}},
		{" 01                Three.co.uk   qmtestuser    qmtestpass    IPV4V6        CHAP        ", profile{apn: "Three.co.uk", user: "qmtestuser", pass: "qmtestpass", pdp: "IPV4V6", auth: 2}},
		{" 01                Three.co.uk   qmtestuser    qmtestpass    IPV4V6        PAP or CHAP ", profile{apn: "Three.co.uk", user: "qmtestuser", pass: "qmtestpass", pdp: "IPV4V6", auth: 3}},
		// an APN wider than its column pushes the rest right
		{" 01                mobile.o2.co.uk o2web       password      IPV4V6        PAP         ", profile{apn: "mobile.o2.co.uk", user: "o2web", pass: "password", pdp: "IPV4V6", auth: 1}},
		{" 01                mobile.o2.co.uk                             IPV4          NONE        ", profile{apn: "mobile.o2.co.uk", pdp: "IPV4"}},
		// username only, and a profile name
		{" 01                internet      bob                         IPV6          CHAP        ", profile{apn: "internet", user: "bob", pdp: "IPV6", auth: 2}},
		{" 01  myprofile     internet                                  IPV4V6        NONE        ", profile{name: "myprofile", apn: "internet", pdp: "IPV4V6"}},
	}
	for _, c := range cases {
		got, ok := parseProfile(profileHdr + c.row + "\n")
		if !ok || got != c.want {
			t.Errorf("%q\n got  %+v\n want %+v", c.row, got, c.want)
		}
	}
	if _, ok := parseProfile("rc: 0, error: 0\n"); ok {
		t.Error("parsed a profile from empty output")
	}
}

func TestRedact(t *testing.T) {
	in := `AT+QICSGP=1,3,"three.co.uk","user","s3cret",1`
	if got := redact(in); got != `AT+QICSGP=1,3,"three.co.uk","user","***",1` {
		t.Fatalf("redact: %s", got)
	}
	if got := redact(`AT+CGDCONT=1,"IPV4V6","x"`); got != `AT+CGDCONT=1,"IPV4V6","x"` {
		t.Fatalf("redact changed an unrelated command: %s", got)
	}
}

func TestWriteProfileRejects(t *testing.T) {
	for _, p := range []profile{
		{apn: "bad apn", pdp: "IPV4V6"},
		{apn: "ok", pdp: "IPV4V6", user: "has space", auth: 1},
		{apn: "ok", pdp: "IPV4V6", pass: `quo"te`, auth: 1},
		{apn: "ok", pdp: "IPV4V6", auth: 4},
		{apn: "ok", pdp: "X"},
	} {
		if writeProfile(p) != "ERROR" {
			t.Errorf("accepted %+v", p)
		}
	}
}
