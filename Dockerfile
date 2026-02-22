FROM mcr.microsoft.com/powershell:lts-alpine-3.20

RUN mkdir -p /app /state /plugins /config

COPY ReminderEngine.psm1   /app/ReminderEngine.psm1
COPY main.ps1              /app/main.ps1
COPY plugins/              /plugins/

WORKDIR /

CMD ["pwsh", "-File", "/app/main.ps1"]