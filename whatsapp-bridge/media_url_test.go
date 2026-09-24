package main

import "testing"

func TestExtractDirectPathFromURLPreservesQuery(t *testing.T) {
	mms3 := "https://mmg.whatsapp.net/o1/v/t24/f2/m235/AQMexample?ccb=9-4&oh=01_Q5Aa5gFR&oe=6ADB268C&_nc_sid=e6ed6c&mms3=true"
	got := extractDirectPathFromURL(mms3)
	want := "/o1/v/t24/f2/m235/AQMexample?ccb=9-4&oh=01_Q5Aa5gFR&oe=6ADB268C&_nc_sid=e6ed6c&mms3=true"
	if got != want {
		t.Fatalf("mms3 direct path\n got: %s\nwant: %s", got, want)
	}

	legacy := "https://mmg.whatsapp.net/v/t62.7118-24/13812002_n.enc?ccb=11-4&oh=abc&oe=123"
	got = extractDirectPathFromURL(legacy)
	want = "/v/t62.7118-24/13812002_n.enc?ccb=11-4&oh=abc&oe=123"
	if got != want {
		t.Fatalf("legacy direct path\n got: %s\nwant: %s", got, want)
	}
}

func TestExtractDirectPathFromURLDoesNotReencodeQuery(t *testing.T) {
	raw := "https://mmg.whatsapp.net/o1/v/t24/f2/m235/AQM1b66?ccb=9-4&oh=01_Q5Aa5gFR9YJAWsjg4dlhzNzz6Lo-VLGITcffiKHUQl01xwFT4Q&oe=6ADB268C"
	got := extractDirectPathFromURL(raw)
	if got != "/o1/v/t24/f2/m235/AQM1b66?ccb=9-4&oh=01_Q5Aa5gFR9YJAWsjg4dlhzNzz6Lo-VLGITcffiKHUQl01xwFT4Q&oe=6ADB268C" {
		t.Fatalf("query was rewritten: %s", got)
	}
}

func TestExtractDirectPathFromURLNoQuery(t *testing.T) {
	got := extractDirectPathFromURL("https://mmg.whatsapp.net/v/t62.7118-24/file.enc")
	if got != "/v/t62.7118-24/file.enc" {
		t.Fatalf("got %s", got)
	}
}

func TestExtractDirectPathFromURLAlreadyDirect(t *testing.T) {
	direct := "/o1/v/t24/f2/m235/AQM1?ccb=9-4&oh=token&oe=6ADB268C"
	if got := extractDirectPathFromURL(direct); got != direct {
		t.Fatalf("got %s", got)
	}
}

func TestUniqueMediaFilename(t *testing.T) {
	got := uniqueMediaFilename("3A7F08CEF351B5FF7163", "image_20260923_204015.jpg", "image")
	want := "image_20260923_204015_3A7F08CEF351B5FF7163.jpg"
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	already := uniqueMediaFilename("3A7F08CEF351B5FF7163", want, "image")
	if already != want {
		t.Fatalf("id was duplicated: %s", already)
	}
}
