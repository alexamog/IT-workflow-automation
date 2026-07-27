<#
    TacticalRMM-RestExamples.ps1  -  minimal Tactical RMM REST skeletons.
    Dot-source it, then call the functions. Needs these env vars:
        TRMM_APIKEY  API key from Settings > Global Settings > API Keys
        TRMM_URL     the api. subdomain: https://api.contoso.ca
                     (NOT https://rmm.contoso.ca - that is the web UI)

    Agents are identified by agent_id (a long hex string, NOT the hostname).
    Use Find-TrmmAgent to look one up by hostname first.
    Full API docs: https://docs.tacticalrmm.com/functions/api/
#>

# One wrapper for every call: X-API-KEY auth + Invoke-RestMethod.
# Capture-then-emit: Invoke-RestMethod returns a JSON array as ONE object in
# Windows PowerShell 5.1; emitting it via a variable unrolls it properly.
function Trmm ($Method, $Path, $Body) {
    $headers = @{ 'X-API-KEY' = $env:TRMM_APIKEY; 'Content-Type' = 'application/json' }
    $params  = @{ Uri = "$($env:TRMM_URL.TrimEnd('/'))/$Path"; Headers = $headers; Method = $Method }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json) }
    $result = Invoke-RestMethod @params
    $result
}

# All clients (organizations) and their sites.
function Get-TrmmClients { Trmm GET 'clients/' }

# All agents (every machine with the TRMM agent installed).
function Get-TrmmAgents { Trmm GET 'agents/' }

# Find agents whose hostname contains a keyword. Returns hostname, agent_id,
# client/site, last seen, and logged-in user - the fields you need most.
function Find-TrmmAgent ($keyword) {
    Get-TrmmAgents |
        Where-Object { $_.hostname -match $keyword } |
        Select-Object hostname, agent_id, client_name, site_name, status, last_seen, logged_username
}

# Full detail for one agent (pass the agent_id from Find-TrmmAgent).
function Get-TrmmAgent ($agentId) { Trmm GET "agents/$agentId/" }

# Run a shell command on an agent and wait for the output.
function Invoke-TrmmCommand ($agentId, $command, $timeout = 60) {
    Trmm POST "agents/$agentId/cmd/" @{ shell = 'powershell'; cmd = $command; timeout = $timeout }
}

# Scripts stored in TRMM (id + name), and how to run one on an agent.
function Get-TrmmScripts { Trmm GET 'scripts/' | Select-Object id, name, category }
function Invoke-TrmmScript ($agentId, $scriptId, $timeout = 120) {
    Trmm POST "agents/$agentId/runscript/" @{ script = $scriptId; output = 'wait'; args = @(); timeout = $timeout }
}

# Reboot an agent (immediately - warn whoever is on it first).
function Restart-TrmmAgent ($agentId) { Trmm POST "agents/$agentId/reboot/" }

# --- examples ---
# Get-TrmmClients | Select-Object id, name
# Find-TrmmAgent 'FRONTDESK'
# $a = (Find-TrmmAgent 'FRONTDESK-02').agent_id
# Get-TrmmAgent $a | Select-Object hostname, operating_system, total_ram, needs_reboot
# Invoke-TrmmCommand $a 'Get-PSDrive C | Select-Object Free'
# Get-TrmmScripts | Where-Object name -match 'cleanup'
