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
