unit Tests.Integration.RateLimit;

interface

uses
  DUnitX.TestFramework, Horse, Horse.Commons, Horse.RateLimit, RESTRequest4D,
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
  end;

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

initialization
  TDUnitX.RegisterTestFixture(TTestIntegrationRateLimit);

end.
