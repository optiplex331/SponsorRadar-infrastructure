{{- define "sr.labels" -}}
app.kubernetes.io/name: sponsor-radar
app.kubernetes.io/component: {{ . }}
app.kubernetes.io/part-of: sponsor-radar
{{- end }}

{{- define "sr.selector" -}}
app.kubernetes.io/name: sponsor-radar
app.kubernetes.io/component: {{ . }}
{{- end }}

{{- define "sr.image" -}}
{{ .Values.image.repository }}@{{ required "image.digest is required (sha256:...)" .Values.image.digest }}
{{- end }}

{{/* Pod-level security for the product image (uid 10001). */}}
{{- define "sr.appPodSecurity" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "sr.containerSecurity" -}}
runAsNonRoot: true
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
{{- end }}

{{/* DATABASE_URL via dependent env var expansion; PGPASSWORD must come first. */}}
{{- define "sr.dbEnv" -}}
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: sponsor-radar-postgres
      key: password
- name: DATABASE_URL
  value: postgresql://radar:$(PGPASSWORD)@postgres:5432/radar
{{- end }}
