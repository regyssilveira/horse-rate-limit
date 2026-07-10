unit Tests.Integration.RateLimit;

interface

uses
  DUnitX.TestFramework, Horse, Horse.Commons, Horse.RateLimit, Horse.RateLimit.Storage.Redis,
  Horse.RateLimit.IPHelper, RESTRequest4D,
  System.SysUtils, System.Classes, System.Threading, System.SyncObjs, System.DateUtils,
  Tests.CleanupHelper;

type
  [TestFixture]
  TTestIntegrationRateLimit = class
  private
    const TEST_PORT = 9199;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TearDownFixture]
    procedure TearDownFixture;

    [Test]
    procedure TestLimitDefault;
    [Test]
    procedure TestCustomKeyGenerator;
    [Test]
    procedure TestCustomErrorMessage;
    [Test]
    procedure TestConcurrency;
    [Test]
    procedure TestSlidingWindow;
    [Test]
    procedure TestWhitelistBlacklist;
    [Test]
    procedure TestSkipWhen;
    [Test]
    procedure TestTrustProxy;
    [Test]
    procedure TestCustomErrorJSON;
    [Test]
    procedure TestRedisStorageMock;
    
    // Novos testes da Fase 2
    [Test]
    procedure TestCIDRSubnetValidation;
    [Test]
    procedure TestHiddenHeaders;
    [Test]
    procedure TestCustomHeaders;
    [Test]
    procedure TestMetricsReport;
  end;

var
  GMetricReported: Boolean = False;
  GMetricClientIP: string = '';

implementation

{ TTestIntegrationRateLimit }

procedure TTestIntegrationRateLimit.SetupFixture;
begin
  // Rota 1: Limite padrão rápido (3 requisições por 2 segundos por IP)
  THorse.Get('/limit/default',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(3)
        .WindowSeconds(2)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 2: Limite com chave customizada via Header X-Api-Token (2 requisições por 2 segundos)
  THorse.Get('/limit/custom-key',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(2)
        .WindowSeconds(2)
        .KeyGenerator(
          function(Req: THorseRequest): string
          begin
            Result := Req.Headers['X-Api-Token'];
            if Result = '' then
              Result := Req.RawWebRequest.RemoteAddr;
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 3: Limite com mensagem de erro customizada (1 requisição por 2 segundos)
  THorse.Get('/limit/custom-message',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(1)
        .WindowSeconds(2)
        .ErrorMessage('Acesso negado por limite de taxa')
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 4: Limite para testes de concorrência pura (10 requisições por 5 segundos)
  THorse.Get('/limit/concurrency',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(10)
        .WindowSeconds(5)
        .KeyGenerator(
          function(Req: THorseRequest): string
          begin
            Result := Req.Headers['X-Api-Token'];
            if Result = '' then
              Result := Req.RawWebRequest.RemoteAddr;
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 5: Sliding Window (3 requisições por 2 segundos)
  THorse.Get('/limit/sliding-window',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(3)
        .WindowSeconds(2)
        .Algorithm(rlaSlidingWindow)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 6: Whitelist e Blacklist (suporta múltiplos loopbacks locais)
  THorse.Get('/limit/whitelist-blacklist',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(1)
        .WindowSeconds(5)
        .Whitelist(['127.0.0.1', '::1', '0:0:0:0:0:0:0:1', 'localhost'])
        .Blacklist(['192.168.1.100'])
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 7: SkipWhen (Bypass seguro e robusto)
  THorse.Get('/limit/skip',
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
              if SameText(LKey, 'X-Skip-Limit') then
              begin
                Result := Req.Headers.Dictionary[LKey] = 'true';
                Break;
              end;
            end;
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 8: Trust Proxy
  THorse.Get('/limit/trust-proxy',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(2)
        .WindowSeconds(5)
        .TrustProxy(True)
        .ProxyHeader('X-Custom-Client-IP')
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 9: Erro Customizado JSON
  THorse.Get('/limit/custom-error-json',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(1)
        .WindowSeconds(5)
        .OnError(
          procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo; const ErrorMsg: string)
          begin
            Res.Status(THTTPStatus.TooManyRequests)
              .RawWebResponse.ContentType := 'application/json';
            Res.Send('{"error":"custom_rate_limit_exceeded","limit":' + Info.Limit.ToString + '}');
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 10: Ocultação de Headers (ExposeHeaders = False)
  THorse.Get('/limit/hidden-headers',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(2)
        .WindowSeconds(5)
        .ExposeHeaders(False)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 11: Renomeação de Headers
  THorse.Get('/limit/custom-headers',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(2)
        .WindowSeconds(5)
        .HeaderLimitName('Limit-Total')
        .HeaderRemainingName('Limit-Restante')
        .HeaderResetName('Limit-Zerar')
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Rota 12: Telemetria de Métricas
  THorse.Get('/limit/metrics',
    [THorseRateLimit.New(
      THorseRateLimitConfig.Default
        .Limit(5)
        .WindowSeconds(5)
        .OnMetricsReport(
          procedure(const Info: THorseRateLimitMetricInfo)
          begin
            GMetricReported := True;
            GMetricClientIP := Info.ClientIP;
          end)
    )],
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('OK');
    end);

  // Inicializar o servidor Horse em thread secundária
  TThread.CreateAnonymousThread(
    procedure
    begin
      THorse.Listen(TEST_PORT);
    end).Start;

  Sleep(2000); // Aguardar inicialização do socket
end;

procedure TTestIntegrationRateLimit.TearDownFixture;
begin
  ClearGlobalState;
  Sleep(500);
end;

procedure TTestIntegrationRateLimit.TestLimitDefault;
var
  LReq: IRequest;
  LRes: IResponse;
  I: Integer;
begin
  LReq := TRequest.New;

  // As primeiras 3 requisições devem passar (limite é 3)
  for I := 1 to 3 do
  begin
    LRes := LReq.BaseURL(Format('http://localhost:%d/limit/default', [TEST_PORT]))
      .Accept('text/plain')
      .Get;
    Assert.AreEqual(200, LRes.StatusCode, Format('Requisicao %d deveria ser HTTP 200', [I]));
    Assert.AreEqual('3', LRes.Headers.Values['X-RateLimit-Limit']);
    Assert.AreEqual((3 - I).ToString, LRes.Headers.Values['X-RateLimit-Remaining']);
    Assert.IsNotEmpty(LRes.Headers.Values['X-RateLimit-Reset']);
  end;

  // A 4a requisição deve ser bloqueada (HTTP 429)
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/default', [TEST_PORT]))
    .Accept('text/plain')
    .Get;
  Assert.AreEqual(429, LRes.StatusCode, 'Requisicao 4 deveria ser HTTP 429 (Rate Limited)');
  Assert.AreEqual('3', LRes.Headers.Values['X-RateLimit-Limit']);
  Assert.AreEqual('0', LRes.Headers.Values['X-RateLimit-Remaining']);
  Assert.IsNotEmpty(LRes.Headers.Values['Retry-After']);

  // Aguardar expiração da janela (2 segundos)
  Sleep(2500);

  // Quinta requisição deve voltar a passar com sucesso (janela resetada)
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/default', [TEST_PORT]))
    .Accept('text/plain')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode, 'Requisicao apos o reset deveria ser HTTP 200');
  Assert.AreEqual('2', LRes.Headers.Values['X-RateLimit-Remaining']);
end;

procedure TTestIntegrationRateLimit.TestCustomKeyGenerator;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;

  // Testar com TokenA: 2 requisições permitidas
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-key', [TEST_PORT]))
    .AddHeader('X-Api-Token', 'TokenA')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode);
  Assert.AreEqual('1', LRes.Headers.Values['X-RateLimit-Remaining']);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-key', [TEST_PORT]))
    .AddHeader('X-Api-Token', 'TokenA')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode);
  Assert.AreEqual('0', LRes.Headers.Values['X-RateLimit-Remaining']);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-key', [TEST_PORT]))
    .AddHeader('X-Api-Token', 'TokenA')
    .Get;
  Assert.AreEqual(429, LRes.StatusCode, 'TokenA excedeu o limite e deve ser bloqueado');

  // TokenB deve passar livremente, pois as chaves são isoladas
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-key', [TEST_PORT]))
    .AddHeader('X-Api-Token', 'TokenB')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode, 'TokenB deve estar livre de interferencias do TokenA');
  Assert.AreEqual('1', LRes.Headers.Values['X-RateLimit-Remaining']);
end;

procedure TTestIntegrationRateLimit.TestCustomErrorMessage;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;

  // Primeira requisição passa
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-message', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);

  // Segunda requisição excede o limite
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-message', [TEST_PORT])).Get;
  Assert.AreEqual(429, LRes.StatusCode);
  Assert.AreEqual('Acesso negado por limite de taxa', LRes.Content, 'Corpo do erro 429 deve ser a mensagem configurada');
end;

procedure TTestIntegrationRateLimit.TestConcurrency;
const
  NUM_THREADS = 4;
  REQS_PER_THREAD = 3;
var
  LTasks: array[0..NUM_THREADS - 1] of ITask;
  I: Integer;
  LFailed: Boolean;
  LFailMessage: string;
  LFailedCS: TCriticalSection;
begin
  LFailed := False;
  LFailMessage := '';
  LFailedCS := TCriticalSection.Create;
  try
    for I := 0 to NUM_THREADS - 1 do
    begin
      LTasks[I] := TTask.Create(
        procedure
        var
          LReq: IRequest;
          LRes: IResponse;
          K: Integer;
          LToken: string;
        begin
          LToken := Format('ConcurrentToken_%d', [TThread.CurrentThread.ThreadID]);
          for K := 1 to REQS_PER_THREAD do
          begin
            try
              LReq := TRequest.New;
              LRes := LReq.BaseURL(Format('http://localhost:%d/limit/concurrency', [TEST_PORT]))
                .AddHeader('X-Api-Token', LToken)
                .Get;
              
              if LRes.StatusCode <> 200 then
              begin
                LFailedCS.Enter;
                LFailed := True;
                LFailMessage := Format('Concorrencia: Status esperado 200 mas obteve %d para chave %s (req %d)', [LRes.StatusCode, LToken, K]);
                LFailedCS.Leave;
              end;
            except
              on E: Exception do
              begin
                LFailedCS.Enter;
                LFailed := True;
                LFailMessage := 'Erro concorrente: ' + E.Message;
                LFailedCS.Leave;
              end;
            end;
          end;
        end);
      LTasks[I].Start;
    end;

    TTask.WaitForAll(LTasks);
    Assert.IsFalse(LFailed, 'Falha no teste concorrente multi-thread: ' + LFailMessage);
  finally
    LFailedCS.Free;
  end;
end;

procedure TTestIntegrationRateLimit.TestSlidingWindow;
var
  LReq: IRequest;
  LRes: IResponse;
  I: Integer;
begin
  LReq := TRequest.New;

  // Permite 3 requisições
  for I := 1 to 3 do
  begin
    LRes := LReq.BaseURL(Format('http://localhost:%d/limit/sliding-window', [TEST_PORT])).Get;
    Assert.AreEqual(200, LRes.StatusCode, Format('Sliding: Requisicao %d falhou', [I]));
  end;

  // A 4a deve ser bloqueada
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/sliding-window', [TEST_PORT])).Get;
  Assert.AreEqual(429, LRes.StatusCode, 'Sliding: A 4a requisicao deveria ser bloqueada (429)');
end;

procedure TTestIntegrationRateLimit.TestWhitelistBlacklist;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;

  // Como o teste roda em localhost (127.0.0.1 ou ::1), ele está na Whitelist da rota
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/whitelist-blacklist', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/whitelist-blacklist', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode, 'Deveria passar pois localhost esta na Whitelist');
end;

procedure TTestIntegrationRateLimit.TestSkipWhen;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;

  // Passando cabeçalho especial que ativa o SkipWhen
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/skip', [TEST_PORT]))
    .AddHeader('X-Skip-Limit', 'true')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/skip', [TEST_PORT]))
    .AddHeader('X-Skip-Limit', 'true')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode, 'Deveria pular o limite devido ao SkipWhen');

  // Sem o cabeçalho, deve bater no limite após a 1a requisição (reinstanciando LReq para limpar os headers)
  LReq := TRequest.New;
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/skip', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/skip', [TEST_PORT])).Get;
  Assert.AreEqual(429, LRes.StatusCode, 'Deveria bater no limite sem o cabecalho de skip');
end;

procedure TTestIntegrationRateLimit.TestTrustProxy;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/trust-proxy', [TEST_PORT]))
    .AddHeader('X-Custom-Client-IP', '10.0.0.1')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode);
  Assert.AreEqual('1', LRes.Headers.Values['X-RateLimit-Remaining']);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/trust-proxy', [TEST_PORT]))
    .AddHeader('X-Custom-Client-IP', '10.0.0.2')
    .Get;
  Assert.AreEqual(200, LRes.StatusCode);
  Assert.AreEqual('1', LRes.Headers.Values['X-RateLimit-Remaining']);
end;

procedure TTestIntegrationRateLimit.TestCustomErrorJSON;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-error-json', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);

  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-error-json', [TEST_PORT])).Get;
  Assert.AreEqual(429, LRes.StatusCode);
  Assert.AreEqual('application/json', LRes.Headers.Values['Content-Type']);
  Assert.IsTrue(LRes.Content.Contains('"error":"custom_rate_limit_exceeded"'), 'Deveria retornar o JSON customizado');
end;

procedure TTestIntegrationRateLimit.TestRedisStorageMock;
var
  LStorage: IHorseRateLimitStorageEx;
  LEvalCalled: Boolean;
  LInfo: THorseRateLimitInfo;
begin
  LEvalCalled := False;
  
  LStorage := THorseRateLimitRedisStorage.Create(
    function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>
    var
      LRet: TArray<string>;
    begin
      LEvalCalled := True;
      Assert.AreEqual('test-key', AKeys[0]);
      Assert.AreEqual('10', AArgs[0]);
      Assert.AreEqual('60', AArgs[1]);
      
      SetLength(LRet, 3);
      LRet[0] := '5';
      LRet[1] := '45';
      LRet[2] := '0';
      Result := LRet;
    end);

  LInfo := LStorage.EvaluateEx('test-key', 10, 60, rlaFixedWindow);
  
  Assert.IsTrue(LEvalCalled, 'O callback do Redis Eval deveria ter sido chamado');
  Assert.AreEqual(5, LInfo.Remaining);
  Assert.IsFalse(LInfo.IsBlocked);
end;

procedure TTestIntegrationRateLimit.TestCIDRSubnetValidation;
begin
  // IPv4
  Assert.IsTrue(IsIPInCIDR('192.168.1.50', '192.168.1.0/24'));
  Assert.IsTrue(IsIPInCIDR('10.0.0.12', '10.0.0.0/8'));
  Assert.IsFalse(IsIPInCIDR('192.168.2.1', '192.168.1.0/24'));
  
  // IPv6
  Assert.IsTrue(IsIPInCIDR('fe80::1', 'fe80::/10'));
  Assert.IsTrue(IsIPInCIDR('::1', '::1/128'));
  Assert.IsFalse(IsIPInCIDR('2001:db8::1', 'fe80::/10'));
end;

procedure TTestIntegrationRateLimit.TestHiddenHeaders;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/hidden-headers', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);
  Assert.IsEmpty(LRes.Headers.Values['X-RateLimit-Limit']);
  Assert.IsEmpty(LRes.Headers.Values['X-RateLimit-Remaining']);
end;

procedure TTestIntegrationRateLimit.TestCustomHeaders;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  LReq := TRequest.New;
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/custom-headers', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);
  Assert.AreEqual('2', LRes.Headers.Values['Limit-Total']);
  Assert.AreEqual('1', LRes.Headers.Values['Limit-Restante']);
  Assert.IsNotEmpty(LRes.Headers.Values['Limit-Zerar']);
end;

procedure TTestIntegrationRateLimit.TestMetricsReport;
var
  LReq: IRequest;
  LRes: IResponse;
begin
  GMetricReported := False;
  GMetricClientIP := '';
  
  LReq := TRequest.New;
  LRes := LReq.BaseURL(Format('http://localhost:%d/limit/metrics', [TEST_PORT])).Get;
  Assert.AreEqual(200, LRes.StatusCode);
  
  Sleep(150); // Aguarda o disparo
  Assert.IsTrue(GMetricReported, 'O evento de metricas deveria ter sido disparado');
  Assert.IsNotEmpty(GMetricClientIP, 'O IP nas metricas nao deveria estar vazio');
end;

initialization
  TDUnitX.RegisterTestFixture(TTestIntegrationRateLimit);

end.
