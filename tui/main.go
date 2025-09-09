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
	}
}

func (m Model) Init() tea.Cmd {
	return loadProcesses
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "r":
			m.loading = true
			return m, loadProcesses
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
		"Enter: Restart",
		"s: Start",
		"x: Stop",
		"r: Refresh",
		"q: Quit",
	}
	b.WriteString(helpStyle.Render(strings.Join(help, " • ")))

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

func main() {
	p := tea.NewProgram(initialModel())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running TUI: %v\n", err)
		os.Exit(1)
	}
}