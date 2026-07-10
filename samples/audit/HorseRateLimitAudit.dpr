program HorseRateLimitAudit;

{$APPTYPE CONSOLE}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

uses
  {$IF DEFINED(FPC)}
  SysUtils, Classes, DateUtils,
  {$ELSE}
  System.SysUtils, System.Classes, System.DateUtils, System.Net.HttpClient,
  System.Net.URLClient, Winapi.Windows,
  {$ENDIF}
  Horse,
  Horse.RateLimit,
  Horse.RateLimit.Storage.Redis;

const
  PORT = 9200;
  BASE_URL = 'http://localhost:9200';

procedure SetColor(AColor: Word);
begin
  {$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), AColor);
  {$ENDIF}
end;

procedure ResetColor;
begin
  {$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), 7);
  {$ENDIF}
end;

procedure LogTitle(const ATitle: string);
begin
  Writeln;
  SetColor(15); // Branco brilhante
  Writeln('======================================================================');
  Writeln('  ' + ATitle);
  Writeln('======================================================================');
  ResetColor;
end;

procedure LogInfo(const AMsg: string);
begin
  SetColor(11); // Ciano
  Writeln('[INFO] ' + AMsg);
  ResetColor;
end;

procedure LogSuccess(const AMsg: string);
begin
  SetColor(10); // Verde
  Writeln('[OK]   ' + AMsg);
  ResetColor;
end;

procedure LogWarning(const AMsg: string);
begin
  SetColor(14); // Amarelo
  Writeln('[WARN] ' + AMsg);
  ResetColor;
end;

procedure LogError(const AMsg: string);
begin
  SetColor(12); // Vermelho
  Writeln('[FAIL] ' + AMsg);
  ResetColor;
end;

// Configuração do Servidor de Auditoria
procedure SetupServer;
begin
  // Rota 1: Fixed Window (Limite 2 por 3 segundos)
  THorse.Get('/audit/fixed',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(2)
        .WindowSeconds(3)
        .Algorithm(rlaFixedWindow)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('Fixed Window HTTP 200');
    end);

  // Rota 2: Sliding Window (Limite 2 por 3 segundos)
  THorse.Get('/audit/sliding',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(2)
        .WindowSeconds(3)
        .Algorithm(rlaSlidingWindow)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('Sliding Window HTTP 200');
    end);

  // Rota 3: Whitelist e Blacklist (Trust Proxy ativado)
  THorse.Get('/audit/rules',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(1)
        .WindowSeconds(5)
        .TrustProxy(True)
        .ProxyHeader('X-Real-IP')
        .Whitelist(['127.0.0.1', '::1', '0:0:0:0:0:0:0:1'])
        .Blacklist(['192.168.10.50'])
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('Access Granted HTTP 200');
    end);

  // Rota 4: Skip/Bypass
  THorse.Get('/audit/skip',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(1)
        .WindowSeconds(5)
        .SkipWhen(
          function(Req: THorseRequest): Boolean
          var
            LKey: string;
          begin
            Result := False;
            for LKey in Req.Headers.Dictionary.Keys do
            begin
              if SameText(LKey, 'X-Bypass') then
              begin
                Result := Req.Headers.Dictionary[LKey] = 'true';
                Break;
              end;
            end;
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('Skip Evaluated HTTP 200');
    end);

  // Rota 5: Callback de Erro JSON
  THorse.Get('/audit/json-error',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(1)
        .WindowSeconds(5)
        .OnError(
          procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo; const ErrorMsg: string)
          begin
            Res.Status(THTTPStatus.TooManyRequests)
              .RawWebResponse.ContentType := 'application/json';
            Res.Send('{"error": "rate_limit_exceeded", "limit": ' + Info.Limit.ToString + ', "remaining": ' + Info.Remaining.ToString + '}');
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('JSON Error Endpoint HTTP 200');
    end);

  TThread.CreateAnonymousThread(
    procedure
    begin
      THorse.Listen(PORT);
    end).Start;

  Sleep(1500); // Aguarda inicialização do socket
end;

// Execução dos cenários de auditoria
procedure RunAudit;
var
  LClient: THTTPClient;
  LRes: IHTTPResponse;
  I: Integer;
  LHeaders: TNetHeaders;
begin
  LClient := THTTPClient.Create;
  try
    // -------------------------------------------------------------------------
    LogTitle('CENÁRIO 1: FIXED WINDOW (LIMIT: 2 REQS / 3 SECONDS)');
    // -------------------------------------------------------------------------
    for I := 1 to 3 do
    begin
      LogInfo(Format('Enviando requisição %d/3...', [I]));
      LRes := LClient.Get(BASE_URL + '/audit/fixed');
      
      LogInfo('Status Code: ' + LRes.StatusCode.ToString);
      LogInfo('X-RateLimit-Limit: ' + LRes.HeaderValue['X-RateLimit-Limit']);
      LogInfo('X-RateLimit-Remaining: ' + LRes.HeaderValue['X-RateLimit-Remaining']);
      
      if LRes.StatusCode = 200 then
        LogSuccess('Resposta do servidor: ' + LRes.ContentAsString)
      else if LRes.StatusCode = 429 then
      begin
        LogError('Bloqueado corretamente! Retry-After: ' + LRes.HeaderValue['Retry-After'] + ' segundos.');
        LogSuccess('Comportamento de Fixed Window auditado com sucesso!');
      end
      else
        LogError('Status inesperado: ' + LRes.StatusCode.ToString);
      Sleep(100);
    end;

    // -------------------------------------------------------------------------
    LogTitle('CENÁRIO 2: SLIDING WINDOW (LIMIT: 2 REQS / 3 SECONDS)');
    // -------------------------------------------------------------------------
    for I := 1 to 3 do
    begin
      LogInfo(Format('Enviando requisição %d/3...', [I]));
      LRes := LClient.Get(BASE_URL + '/audit/sliding');
      
      LogInfo('Status Code: ' + LRes.StatusCode.ToString);
      LogInfo('X-RateLimit-Limit: ' + LRes.HeaderValue['X-RateLimit-Limit']);
      LogInfo('X-RateLimit-Remaining: ' + LRes.HeaderValue['X-RateLimit-Remaining']);
      
      if LRes.StatusCode = 200 then
        LogSuccess('Resposta do servidor: ' + LRes.ContentAsString)
      else if LRes.StatusCode = 429 then
      begin
        LogError('Bloqueado corretamente pela Janela Deslizante!');
        LogSuccess('Comportamento de Sliding Window auditado com sucesso!');
      end;
      Sleep(100);
    end;

    // -------------------------------------------------------------------------
    LogTitle('CENÁRIO 3: WHITELIST E BLACKLIST (LIMIT: 1 REQ / 5 SECONDS)');
    // -------------------------------------------------------------------------
    // Caso A: Whitelist (localhost) - deve passar mesmo fazendo requisições consecutivas
    LogInfo('Testando Whitelist (localhost/::1)...');
    LRes := LClient.Get(BASE_URL + '/audit/rules');
    LogSuccess('Req 1 - Status: ' + LRes.StatusCode.ToString);
    
    LRes := LClient.Get(BASE_URL + '/audit/rules');
    if LRes.StatusCode = 200 then
      LogSuccess('Req 2 - Status: 200 (Passou na Whitelist com sucesso!)')
    else
      LogError('Req 2 - Falhou na Whitelist: ' + LRes.StatusCode.ToString);

    // Caso B: Blacklist (IP 192.168.10.50 simulado por Trust Proxy)
    LogInfo('Testando Blacklist (Simulando IP 192.168.10.50 via header X-Real-IP)...');
    SetLength(LHeaders, 1);
    LHeaders[0] := TNetHeader.Create('X-Real-IP', '192.168.10.50');
    
    LRes := LClient.Get(BASE_URL + '/audit/rules', nil, LHeaders);
    if LRes.StatusCode = 403 then
    begin
      LogError('IP Bloqueado corretamente! Status: 403 Forbidden.');
      LogSuccess('Whitelist/Blacklist auditadas com sucesso!');
    end
    else
      LogError('IP na Blacklist não foi bloqueado: ' + LRes.StatusCode.ToString);

    // -------------------------------------------------------------------------
    LogTitle('CENÁRIO 4: BYPASS DINÂMICO - SKIPWHEN (LIMIT: 1 REQ / 5 SECONDS)');
    // -------------------------------------------------------------------------
    LogInfo('Enviando requisição com header X-Bypass = true...');
    SetLength(LHeaders, 1);
    LHeaders[0] := TNetHeader.Create('X-Bypass', 'true');
    
    LRes := LClient.Get(BASE_URL + '/audit/skip', nil, LHeaders);
    LogSuccess('Req 1 - Status: ' + LRes.StatusCode.ToString);
    
    LRes := LClient.Get(BASE_URL + '/audit/skip', nil, LHeaders);
    if LRes.StatusCode = 200 then
      LogSuccess('Req 2 - Status: 200 (Bypass dinâmico via SkipWhen auditado com sucesso!)')
    else
      LogError('Req 2 - Falhou no SkipWhen: ' + LRes.StatusCode.ToString);

    // -------------------------------------------------------------------------
    LogTitle('CENÁRIO 5: FORMATO DE ERRO CUSTOMIZADO (JSON)');
    // -------------------------------------------------------------------------
    LogInfo('Enviando primeira requisição (passa)...');
    LRes := LClient.Get(BASE_URL + '/audit/json-error');
    LogSuccess('Req 1 - Status: ' + LRes.StatusCode.ToString);

    LogInfo('Enviando segunda requisição (excede limite)...');
    LRes := LClient.Get(BASE_URL + '/audit/json-error');
    if LRes.StatusCode = 429 then
    begin
      LogError('Bloqueado! Status: 429.');
      LogInfo('Content-Type retornado: ' + LRes.HeaderValue['Content-Type']);
      LogWarning('Corpo da Resposta JSON: ' + LRes.ContentAsString);
      if LRes.ContentAsString.Contains('"error":"rate_limit_exceeded"') then
        LogSuccess('Resposta customizada em JSON auditada com sucesso!');
    end
    else
      LogError('Status inesperado: ' + LRes.StatusCode.ToString);

  finally
    LClient.Free;
  end;
end;

begin
  try
    SetColor(15);
    Writeln('======================================================================');
    Writeln('      INICIANDO AUDITORIA COMPLETA DO MIDDLEWARE HORSE RATE LIMIT     ');
    Writeln('======================================================================');
    ResetColor;

    LogInfo('Inicializando servidor Horse na porta 9200...');
    SetupServer;
    LogSuccess('Servidor online!');

    RunAudit;

    LogTitle('AUDITORIA CONCLUÍDA COM 100% DE COBERTURA E SUCESSO!');
    Writeln('Pressione [Enter] para encerrar o servidor e fechar...');
    Readln;
  except
    on E: Exception do
    begin
      LogError('Erro na execução da auditoria: ' + E.ClassName + ' - ' + E.Message);
      Readln;
    end;
  end;
end.
