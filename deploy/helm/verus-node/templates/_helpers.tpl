{{/* Chart name, overridable. */}}
{{- define "verus-node.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "verus-node.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "verus-node.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "verus-node.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "verus-node.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "verus-node.selectorLabels" -}}
app.kubernetes.io/name: {{ include "verus-node.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Port defaults.

VRSC and VRSCTEST have compiled-in ports. PBaaS chains derive their P2P port
from the chain definition, so it is unpredictable and MUST be set explicitly —
the chart fails rather than guessing.
*/}}
{{- define "verus-node.p2pPort" -}}
{{- if .Values.ports.p2p -}}
{{- .Values.ports.p2p -}}
{{- else if eq .Values.chain "VRSC" -}}27485
{{- else if eq (upper .Values.chain) "VRSCTEST" -}}18842
{{- else -}}
{{- fail (printf "chain %q is a PBaaS chain: set ports.p2p and ports.rpc explicitly (the daemon derives an unpredictable P2P port)" .Values.chain) -}}
{{- end -}}
{{- end -}}

{{- define "verus-node.rpcPort" -}}
{{- if .Values.ports.rpc -}}
{{- .Values.ports.rpc -}}
{{- else if eq .Values.chain "VRSC" -}}27486
{{- else if eq (upper .Values.chain) "VRSCTEST" -}}18843
{{- else -}}
{{- fail (printf "chain %q is a PBaaS chain: set ports.p2p and ports.rpc explicitly" .Values.chain) -}}
{{- end -}}
{{- end -}}

{{/* Where the chain writes its data: PBaaS chains use a different tree. */}}
{{- define "verus-node.dataMountPath" -}}
{{- $c := upper .Values.chain -}}
{{- if or (eq $c "VRSC") (eq $c "VRSCTEST") -}}
/home/verus/.komodo
{{- else if eq (upper (default "VRSC" .Values.rootChain)) "VRSCTEST" -}}
/home/verus/.verustest
{{- else -}}
/home/verus/.verus
{{- end -}}
{{- end -}}

{{- define "verus-node.secretName" -}}
{{- if .Values.rpcAuth.existingSecret -}}
{{- .Values.rpcAuth.existingSecret -}}
{{- else -}}
{{- printf "%s-rpc" (include "verus-node.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Where the entrypoint writes the generated credentials file.

Must mirror chain_credentials_file() in rootfs/usr/local/lib/verus/chain.sh:
root and testnet chains get <datadir>/rpc-credentials with the datadir cased
exactly as verusd expects, while a PBaaS chain has no predictable datadir and
so gets <home>/<slug>.rpc-credentials instead.
*/}}
{{- define "verus-node.credentialsPath" -}}
{{- $home := include "verus-node.dataMountPath" . -}}
{{- $c := upper .Values.chain -}}
{{- if eq $c "VRSC" -}}
{{ $home }}/VRSC/rpc-credentials
{{- else if eq $c "VRSCTEST" -}}
{{ $home }}/vrsctest/rpc-credentials
{{- else -}}
{{ $home }}/{{ lower .Values.chain }}.rpc-credentials
{{- end -}}
{{- end -}}
