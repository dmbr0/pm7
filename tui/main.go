package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/bubbles/table"
)

const (
	apiBaseURL = "http://localhost:4000/api"
)

// Process represents a process managed by PM7
type Process struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Command     string            `json:"command"`
	Cwd         string            `json:"cwd"`
	Env         map[string]string `json:"env"`
	Status      string            `json:"status"`
	PID         *string           `json:"pid"`
	OSPID       *int              `json:"os_pid"`
	StartedAt   *int64            `json:"started_at"`
	Restarts    int               `json:"restarts"`
	AutoRestart bool              `json:"auto_restart"`
}

// ProcessConfig for creating new processes
type ProcessConfig struct {
	Name        string
	Command     string
	Cwd         string
	Env         string
	AutoRestart bool
}

// API response structures
type APIResponse struct {
	Status  string      `json:"status"`
	Message string      `json:"message"`
	Data    interface{} `json:"data"`
	Error   string      `json:"error"`
}

// Model represents the TUI application state
type Model struct {
	processes []Process
	table     table.Model
	loading   bool
	err       error
	selected  int
	showForm  bool
	formStep  int
	formData  ProcessConfig
}

// Messages for the tea framework
type processesLoadedMsg []Process
type errorMsg error

// Styles for the TUI
var (
	titleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFDF5")).
			Background(lipgloss.Color("#25A065")).
			Padding(0, 1)

	statusStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFDF5")).
			Bold(true)

	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#626262"))
)

func initialModel() Model {
	columns := []table.Column{
		{Title: "ID", Width: 10},
		{Title: "Name", Width: 20},
		{Title: "Status", Width: 10},
		{Title: "PID", Width: 8},
		{Title: "Command", Width: 30},
		{Title: "Restarts", Width: 10},
	}

	t := table.New(
		table.WithColumns(columns),
		table.WithFocused(true),
		table.WithHeight(10),
	)

	s := table.DefaultStyles()
	s.Header = s.Header.
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("240")).
		BorderBottom(true).
		Bold(false)
	s.Selected = s.Selected.
		Foreground(lipgloss.Color("229")).
		Background(lipgloss.Color("57")).
		Bold(false)
	t.SetStyles(s)

	return Model{
		table:   t,
		loading: true,
		formData: ProcessConfig{
			Cwd: "/tmp", // Default working directory
		},
	}
}

func (m Model) Init() tea.Cmd {
	return loadProcesses
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.showForm {
			return m.handleFormInput(msg)
		}
		
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "r":
			m.loading = true
			return m, loadProcesses
		case "c":
			m.showForm = true
			m.formStep = 0
			m.formData = ProcessConfig{Cwd: "/tmp"}
			return m, nil
		case "s":
			if len(m.processes) > 0 && m.table.Cursor() < len(m.processes) {
				process := m.processes[m.table.Cursor()]
				return m, startProcess(process.ID)
			}
		case "x":
			if len(m.processes) > 0 && m.table.Cursor() < len(m.processes) {
				process := m.processes[m.table.Cursor()]
				return m, stopProcess(process.ID)
			}
		case "enter":
			if len(m.processes) > 0 && m.table.Cursor() < len(m.processes) {
				process := m.processes[m.table.Cursor()]
				return m, restartProcess(process.ID)
			}
		case "d":
			if len(m.processes) > 0 && m.table.Cursor() < len(m.processes) {
				process := m.processes[m.table.Cursor()]
				return m, deleteProcess(process.ID)
			}
		}
	case processesLoadedMsg:
		m.processes = []Process(msg)
		m.loading = false
		m.err = nil
		m.updateTable()
	case errorMsg:
		m.err = error(msg)
		m.loading = false
	}

	m.table, cmd = m.table.Update(msg)
	return m, cmd
}

func (m Model) handleFormInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "esc":
		m.showForm = false
		m.formStep = 0
		return m, nil
	case "enter":
		if m.formStep < 4 {
			m.formStep++
		} else {
			// Submit form
			m.showForm = false
			m.formStep = 0
			return m, createProcess(m.formData)
		}
	case "backspace":
		switch m.formStep {
		case 0: // Name
			if len(m.formData.Name) > 0 {
				m.formData.Name = m.formData.Name[:len(m.formData.Name)-1]
			}
		case 1: // Command
			if len(m.formData.Command) > 0 {
				m.formData.Command = m.formData.Command[:len(m.formData.Command)-1]
			}
		case 2: // Working directory
			if len(m.formData.Cwd) > 0 {
				m.formData.Cwd = m.formData.Cwd[:len(m.formData.Cwd)-1]
			}
		case 3: // Environment
			if len(m.formData.Env) > 0 {
				m.formData.Env = m.formData.Env[:len(m.formData.Env)-1]
			}
		}
	case "y", "Y":
		if m.formStep == 4 {
			m.formData.AutoRestart = true
		}
	case "n", "N":
		if m.formStep == 4 {
			m.formData.AutoRestart = false
		}
	default:
		// Regular character input
		if len(msg.String()) == 1 && m.formStep < 4 {
			switch m.formStep {
			case 0: // Name
				m.formData.Name += msg.String()
			case 1: // Command
				m.formData.Command += msg.String()
			case 2: // Working directory
				m.formData.Cwd += msg.String()
			case 3: // Environment
				m.formData.Env += msg.String()
			}
		}
	}
	return m, nil
}

func (m *Model) updateTable() {
	rows := make([]table.Row, len(m.processes))
	for i, process := range m.processes {
		pid := "N/A"
		if process.OSPID != nil {
			pid = fmt.Sprintf("%d", *process.OSPID)
		}

		// Truncate command if too long
		command := process.Command
		if len(command) > 28 {
			command = command[:25] + "..."
		}

		rows[i] = table.Row{
			process.ID[:8] + "...", // Truncate ID
			process.Name,
			process.Status,
			pid,
			command,
			fmt.Sprintf("%d", process.Restarts),
		}
	}
	m.table.SetRows(rows)
}

func (m Model) View() string {
	var b strings.Builder

	// Title
	b.WriteString(titleStyle.Render("PM7 Process Manager"))
	b.WriteString("\n\n")

	if m.showForm {
		return m.renderForm()
	}

	if m.loading {
		b.WriteString("Loading processes...\n")
		return b.String()
	}

	if m.err != nil {
		b.WriteString(fmt.Sprintf("Error: %v\n", m.err))
		b.WriteString("\nPress 'r' to retry, 'q' to quit\n")
		return b.String()
	}

	// Process table
	b.WriteString(m.table.View())
	b.WriteString("\n\n")

	// Status info
	if len(m.processes) > 0 && m.table.Cursor() < len(m.processes) {
		process := m.processes[m.table.Cursor()]
		b.WriteString(statusStyle.Render(fmt.Sprintf("Selected: %s (%s)", process.Name, process.Status)))
		b.WriteString("\n\n")
		b.WriteString(fmt.Sprintf("Command: %s\n", process.Command))
		b.WriteString(fmt.Sprintf("Working Directory: %s\n", process.Cwd))
		if process.StartedAt != nil {
			startTime := time.Unix(*process.StartedAt/1000, 0)
			b.WriteString(fmt.Sprintf("Started: %s\n", startTime.Format("2006-01-02 15:04:05")))
		}
	}

	b.WriteString("\n")

	// Help
	help := []string{
		"↑/↓: Navigate",
		"c: Create",
		"Enter: Restart",
		"s: Start",
		"x: Stop",
		"d: Delete",
		"r: Refresh",
		"q: Quit",
	}
	b.WriteString(helpStyle.Render(strings.Join(help, " • ")))

	return b.String()
}

func (m Model) renderForm() string {
	var b strings.Builder
	
	b.WriteString(titleStyle.Render("Create New Process"))
	b.WriteString("\n\n")

	formStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("62")).
		Padding(1, 2)

	var formContent strings.Builder
	
	// Process Name
	if m.formStep == 0 {
		formContent.WriteString("→ Process Name: " + m.formData.Name + "█\n")
	} else {
		formContent.WriteString("  Process Name: " + m.formData.Name + "\n")
	}
	
	// Command
	if m.formStep == 1 {
		formContent.WriteString("→ Command: " + m.formData.Command + "█\n")
	} else {
		formContent.WriteString("  Command: " + m.formData.Command + "\n")
	}
	
	// Working Directory
	if m.formStep == 2 {
		formContent.WriteString("→ Working Dir: " + m.formData.Cwd + "█\n")
	} else {
		formContent.WriteString("  Working Dir: " + m.formData.Cwd + "\n")
	}
	
	// Environment
	if m.formStep == 3 {
		formContent.WriteString("→ Environment: " + m.formData.Env + "█\n")
	} else {
		formContent.WriteString("  Environment: " + m.formData.Env + "\n")
	}
	
	// Auto Restart
	if m.formStep == 4 {
		restartText := "n"
		if m.formData.AutoRestart {
			restartText = "y"
		}
		formContent.WriteString("→ Auto Restart (y/n): " + restartText + "\n")
	} else {
		restartText := "No"
		if m.formData.AutoRestart {
			restartText = "Yes"
		}
		formContent.WriteString("  Auto Restart: " + restartText + "\n")
	}

	b.WriteString(formStyle.Render(formContent.String()))
	b.WriteString("\n\n")

	// Instructions
	if m.formStep < 4 {
		b.WriteString("Type to enter value, Enter to continue, Esc to cancel")
	} else {
		b.WriteString("Press y/n for auto-restart, Enter to create process, Esc to cancel")
	}

	return b.String()
}

// Commands
func loadProcesses() tea.Msg {
	resp, err := http.Get(apiBaseURL + "/processes")
	if err != nil {
		return errorMsg(fmt.Errorf("failed to fetch processes: %w", err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return errorMsg(fmt.Errorf("failed to read response: %w", err))
	}

	var apiResp APIResponse
	if err := json.Unmarshal(body, &apiResp); err != nil {
		return errorMsg(fmt.Errorf("failed to parse response: %w", err))
	}

	if apiResp.Status != "success" {
		return errorMsg(fmt.Errorf("API error: %s", apiResp.Message))
	}

	// Convert interface{} to []Process
	processesData, err := json.Marshal(apiResp.Data)
	if err != nil {
		return errorMsg(fmt.Errorf("failed to marshal processes: %w", err))
	}

	var processes []Process
	if err := json.Unmarshal(processesData, &processes); err != nil {
		return errorMsg(fmt.Errorf("failed to unmarshal processes: %w", err))
	}

	return processesLoadedMsg(processes)
}

func createProcess(config ProcessConfig) tea.Cmd {
	return func() tea.Msg {
		// Create the request payload
		payload := map[string]interface{}{
			"name":         config.Name,
			"command":      config.Command,
			"cwd":          config.Cwd,
			"auto_restart": config.AutoRestart,
		}
		
		// Parse environment variables if provided
		if config.Env != "" {
			envMap := make(map[string]string)
			lines := strings.Split(config.Env, "\n")
			for _, line := range lines {
				if strings.Contains(line, "=") {
					parts := strings.SplitN(line, "=", 2)
					if len(parts) == 2 {
						envMap[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
					}
				}
			}
			payload["env"] = envMap
		}

		jsonData, err := json.Marshal(payload)
		if err != nil {
			return errorMsg(fmt.Errorf("failed to marshal request: %w", err))
		}

		resp, err := http.Post(apiBaseURL+"/processes", "application/json", strings.NewReader(string(jsonData)))
		if err != nil {
			return errorMsg(fmt.Errorf("failed to create process: %w", err))
		}
		defer resp.Body.Close()

		if resp.StatusCode != 201 {
			body, _ := io.ReadAll(resp.Body)
			return errorMsg(fmt.Errorf("failed to create process: %s", string(body)))
		}

		// Reload processes after creation
		time.Sleep(500 * time.Millisecond) // Give time for process to start
		return loadProcesses()
	}
}

func startProcess(processID string) tea.Cmd {
	return func() tea.Msg {
		resp, err := http.Post(apiBaseURL+"/processes/"+processID+"/start", "application/json", nil)
		if err != nil {
			return errorMsg(fmt.Errorf("failed to start process: %w", err))
		}
		defer resp.Body.Close()

		// Reload processes after action
		time.Sleep(500 * time.Millisecond) // Give the process time to start
		return loadProcesses()
	}
}

func stopProcess(processID string) tea.Cmd {
	return func() tea.Msg {
		resp, err := http.Post(apiBaseURL+"/processes/"+processID+"/stop", "application/json", nil)
		if err != nil {
			return errorMsg(fmt.Errorf("failed to stop process: %w", err))
		}
		defer resp.Body.Close()

		// Reload processes after action
		time.Sleep(500 * time.Millisecond) // Give the process time to stop
		return loadProcesses()
	}
}

func restartProcess(processID string) tea.Cmd {
	return func() tea.Msg {
		resp, err := http.Post(apiBaseURL+"/processes/"+processID+"/restart", "application/json", nil)
		if err != nil {
			return errorMsg(fmt.Errorf("failed to restart process: %w", err))
		}
		defer resp.Body.Close()

		// Reload processes after action
		time.Sleep(1000 * time.Millisecond) // Give the process time to restart
		return loadProcesses()
	}
}

func deleteProcess(processID string) tea.Cmd {
	return func() tea.Msg {
		req, err := http.NewRequest("DELETE", apiBaseURL+"/processes/"+processID, nil)
		if err != nil {
			return errorMsg(fmt.Errorf("failed to create delete request: %w", err))
		}

		client := &http.Client{}
		resp, err := client.Do(req)
		if err != nil {
			return errorMsg(fmt.Errorf("failed to delete process: %w", err))
		}
		defer resp.Body.Close()

		// Reload processes after action
		time.Sleep(500 * time.Millisecond) // Give time for deletion to complete
		return loadProcesses()
	}
}

func main() {
	p := tea.NewProgram(initialModel())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running TUI: %v\n", err)
		os.Exit(1)
	}
}