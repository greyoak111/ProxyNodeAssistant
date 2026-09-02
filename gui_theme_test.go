package main

import (
	"os"
	"strings"
	"testing"
)

// The stock WPF ComboBox template follows the host's light theme for its
// toggle and popup.  Keep this contract close to the source so a future
// cleanup cannot silently bring back white dropdowns with low-contrast text.
func TestGUIInputThemeKeepsDropdownsDark(t *testing.T) {
	source, err := os.ReadFile("gui/MainWindow.xaml")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		`x:Key="DarkComboBoxStyle"`,
		`<Popup x:Name="DropPopup"`,
		`<Border Background="#071116"`,
		`<ToggleButton.Template>`,
		`x:Name="DropChrome"`,
		`OverridesDefaultStyle="True"`,
		`<Trigger Property="IsMouseOver" Value="True">`,
		`<Trigger Property="IsPressed" Value="True">`,
		`<Trigger Property="IsChecked" Value="True">`,
		`<Trigger Property="IsEnabled" Value="False">`,
		`Value="#0A1D24"`,
		`Value="#0D2B34"`,
		`IsEnabled="{TemplateBinding IsEnabled}"`,
		`TextElement.Foreground="{TemplateBinding Foreground}"`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("dark dropdown theme is missing %q", required)
		}
	}

	for _, name := range []string{"ConnectionHistory", "ConnectionAuthMode"} {
		start := strings.Index(text, `x:Name="`+name+`"`)
		if start < 0 {
			t.Fatalf("GUI dropdown %s is missing", name)
		}
		openEnd := strings.Index(text[start:], ">")
		if openEnd < 0 {
			t.Fatalf("GUI dropdown %s opening tag is incomplete", name)
		}
		opening := text[start : start+openEnd]
		if !strings.Contains(opening, `Style="{StaticResource DarkComboBoxStyle}"`) {
			t.Fatalf("GUI dropdown %s does not opt into DarkComboBoxStyle", name)
		}
	}
}

func TestGUITextInputsDeclareReadableDarkColors(t *testing.T) {
	source, err := os.ReadFile("gui/MainWindow.xaml")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, name := range []string{
		"ConnectionHostInput",
		"ConnectionUserInput",
		"ConnectionPortInput",
		"OperationInput",
		"OperationSecretInput",
		"AskPassPassword",
	} {
		start := strings.Index(text, `x:Name="`+name+`"`)
		if start < 0 {
			t.Fatalf("GUI text input %s is missing", name)
		}
		openEnd := strings.Index(text[start:], ">")
		if openEnd < 0 {
			t.Fatalf("GUI text input %s opening tag is incomplete", name)
		}
		opening := text[start : start+openEnd]
		if !strings.Contains(opening, `Background="#`) ||
			(!strings.Contains(opening, `Foreground="#`) && !strings.Contains(opening, `Foreground="White"`)) {
			t.Fatalf("GUI text input %s lacks explicit dark background and readable foreground", name)
		}
	}
}

func TestGUISS2022AllowlistHasSeparateLocalAndCRUDActions(t *testing.T) {
	source, err := os.ReadFile("gui/ProxyNodeAssistant.Gui.cs")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, required := range []string{
		`Op("19", "security", "识别本机 IP 并添加 SS2022 白名单"`,
		`Op("24", "security", "管理 SS2022 白名单"`,
		`Detect local IP and add to SS2022 allowlist`,
		`Manage SS2022 allowlist`,
		`freely add/remove`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("GUI SS2022 allowlist action is missing %q", required)
		}
	}
}
