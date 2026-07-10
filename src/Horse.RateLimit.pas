unit Horse.RateLimit;

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  {$IF DEFINED(FPC)}
  SysUtils, Classes, DateUtils, SyncObjs, Generics.Collections,
  {$ELSE}
  System.SysUtils, System.Classes, System.DateUtils, System.SyncObjs,
  System.Generics.Collections,
  {$ENDIF}
  Horse, Horse.Commons, Horse.Exception.Interrupted;

type
  TRateLimitAlgorithm = (rlaFixedWindow, rlaSlidingWindow);

  THorseRateLimitInfo = record
    Limit: Integer;
    Remaining: Integer;
    ResetTime: TDateTime;
    IsBlocked: Boolean;
  end;

  TKeyGeneratorProc = {$IF DEFINED(FPC)}TFunc<THorseRequest, string>{$ELSE}reference to function(Req: THorseRequest): string{$ENDIF};
  TSkipProc = {$IF DEFINED(FPC)}TFunc<THorseRequest, Boolean>{$ELSE}reference to function(Req: THorseRequest): Boolean{$ENDIF};
  TOnLimitReachedProc = {$IF DEFINED(FPC)}procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo){$ELSE}reference to procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo){$ENDIF};
  TOnErrorProc = {$IF DEFINED(FPC)}procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo; const ErrorMsg: string){$ELSE}reference to procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo; const ErrorMsg: string){$ENDIF};
  TOnCleanupErrorProc = {$IF DEFINED(FPC)}procedure(E: Exception){$ELSE}reference to procedure(E: Exception){$ENDIF};

  IHorseRateLimitStorage = interface
    ['{620F9CC2-4A3C-4C7C-BA80-7C000674C783}']
    function Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
  end;

  IHorseRateLimitStorageEx = interface(IHorseRateLimitStorage)
    ['{84B4BE75-EE2A-4D78-9F10-6C23D8A29A64}']
    function EvaluateEx(const AKey: string; ALimit: Integer; AWindowSeconds: Integer; AAlgorithm: TRateLimitAlgorithm): THorseRateLimitInfo;
    procedure SetOnCleanupError(AProc: TOnCleanupErrorProc);
  end;

  TClientRateLimitInfo = record
    Count: Integer;
    ResetTime: TDateTime;
    PrevCount: Integer;
  end;

  THorseRateLimitMemoryStorage = class(TInterfacedObject, IHorseRateLimitStorage, IHorseRateLimitStorageEx)
  private
    FBuckets: TDictionary<string, TClientRateLimitInfo>;
    FLock: TCriticalSection;
    FLastCleanup: TDateTime;
    FOnCleanupError: TOnCleanupErrorProc;
    procedure DoCleanupExpired;
  public
    constructor Create;
    destructor Destroy; override;
    function Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
    function EvaluateEx(const AKey: string; ALimit: Integer; AWindowSeconds: Integer; AAlgorithm: TRateLimitAlgorithm): THorseRateLimitInfo;
    procedure SetOnCleanupError(AProc: TOnCleanupErrorProc);
  end;

  THorseRateLimitConfig = record
  private
    FLimit: Integer;
    FWindowSeconds: Integer;
    FStorage: IHorseRateLimitStorage;
    FKeyGenerator: TKeyGeneratorProc;
    FErrorMessage: string;
    FAlgorithm: TRateLimitAlgorithm;
    FTrustProxy: Boolean;
    FProxyHeader: string;
    FSkipProc: TSkipProc;
    FWhitelist: TArray<string>;
    FBlacklist: TArray<string>;
    FOnLimitReached: TOnLimitReachedProc;
    FOnError: TOnErrorProc;
    FOnCleanupError: TOnCleanupErrorProc;
  public
    class function Default: THorseRateLimitConfig; static;
    function Limit(ALimit: Integer): THorseRateLimitConfig;
    function WindowSeconds(AWindowSeconds: Integer): THorseRateLimitConfig;
    function Storage(const AStorage: IHorseRateLimitStorage): THorseRateLimitConfig;
    function KeyGenerator(AKeyGenerator: TKeyGeneratorProc): THorseRateLimitConfig;
    function ErrorMessage(const AMessage: string): THorseRateLimitConfig;
    function Algorithm(AAlgorithm: TRateLimitAlgorithm): THorseRateLimitConfig;
    function TrustProxy(ATrust: Boolean): THorseRateLimitConfig;
    function ProxyHeader(const AHeader: string): THorseRateLimitConfig;
    function SkipWhen(AProc: TSkipProc): THorseRateLimitConfig;
    function Whitelist(AIPs: TArray<string>): THorseRateLimitConfig;
    function Blacklist(AIPs: TArray<string>): THorseRateLimitConfig;
    function OnLimitReached(AProc: TOnLimitReachedProc): THorseRateLimitConfig;
    function OnError(AProc: TOnErrorProc): THorseRateLimitConfig;
    function OnCleanupError(AProc: TOnCleanupErrorProc): THorseRateLimitConfig;
  end;

  THorseRateLimit = class
  private
    class var FDefaultStorage: IHorseRateLimitStorage;
    class constructor CreateClass;
  public
    class function New: THorseCallback; overload;
    class function New(const AConfig: THorseRateLimitConfig): THorseCallback; overload;
  end;

implementation

type
  TCleanupThread = class(TThread)
  private
    FStorage: THorseRateLimitMemoryStorage;
  protected
    procedure Execute; override;
  public
    constructor Create(AStorage: THorseRateLimitMemoryStorage);
  end;

{ TCleanupThread }

constructor TCleanupThread.Create(AStorage: THorseRateLimitMemoryStorage);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FStorage := AStorage;
end;

procedure TCleanupThread.Execute;
begin
  try
    FStorage.DoCleanupExpired;
  except
    on E: Exception do
    begin
      if Assigned(FStorage.FOnCleanupError) then
      begin
        try
          FStorage.FOnCleanupError(E);
        except
          // Silencia para não quebrar a thread secundária caso o próprio callback lance exceção
        end;
      end;
    end;
  end;
end;

{ THorseRateLimitMemoryStorage }

constructor THorseRateLimitMemoryStorage.Create;
begin
  inherited Create;
  FBuckets := TDictionary<string, TClientRateLimitInfo>.Create;
  FLock := TCriticalSection.Create;
  FLastCleanup := Now;
  FOnCleanupError := nil;
end;

destructor THorseRateLimitMemoryStorage.Destroy;
begin
  FBuckets.Free;
  FLock.Free;
  inherited Destroy;
end;

function THorseRateLimitMemoryStorage.Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
begin
  Result := EvaluateEx(AKey, ALimit, AWindowSeconds, rlaFixedWindow);
end;

function THorseRateLimitMemoryStorage.EvaluateEx(const AKey: string; ALimit: Integer; AWindowSeconds: Integer; AAlgorithm: TRateLimitAlgorithm): THorseRateLimitInfo;
var
  LInfo: TClientRateLimitInfo;
  LNow: TDateTime;
  LTimePassed: Double;
  LWeight: Double;
  LEstimatedCount: Double;
begin
  LNow := Now;
  
  // Limpeza assíncrona de itens expirados a cada 5 minutos
  FLock.Acquire;
  try
    if MinutesBetween(LNow, FLastCleanup) >= 5 then
    begin
      FLastCleanup := LNow;
      TCleanupThread.Create(Self).Start;
    end;

    if FBuckets.TryGetValue(AKey, LInfo) then
    begin
      if LNow > LInfo.ResetTime then
      begin
        if LNow > IncSecond(LInfo.ResetTime, AWindowSeconds) then
          LInfo.PrevCount := 0
        else
          LInfo.PrevCount := LInfo.Count;

        LInfo.Count := 1;
        LInfo.ResetTime := IncSecond(LNow, AWindowSeconds);
      end
      else
      begin
        LInfo.Count := LInfo.Count + 1;
      end;
    end
    else
    begin
      LInfo.Count := 1;
      LInfo.PrevCount := 0;
      LInfo.ResetTime := IncSecond(LNow, AWindowSeconds);
    end;

    FBuckets.AddOrSetValue(AKey, LInfo);

    Result.Limit := ALimit;
    Result.ResetTime := LInfo.ResetTime;

    if AAlgorithm = rlaSlidingWindow then
    begin
      // Calcula a estimativa da janela deslizante
      LTimePassed := SecondsBetween(LInfo.ResetTime, LNow);
      if LTimePassed > AWindowSeconds then
        LTimePassed := AWindowSeconds;

      LWeight := LTimePassed / AWindowSeconds;
      LEstimatedCount := (LInfo.PrevCount * LWeight) + LInfo.Count;

      Result.Remaining := ALimit - Trunc(LEstimatedCount);
      if Result.Remaining < 0 then
        Result.Remaining := 0;
      Result.IsBlocked := LEstimatedCount > ALimit;
    end
    else
    begin
      Result.Remaining := ALimit - LInfo.Count;
      if Result.Remaining < 0 then
        Result.Remaining := 0;
      Result.IsBlocked := LInfo.Count > ALimit;
    end;
  finally
    FLock.Release;
  end;
end;

procedure THorseRateLimitMemoryStorage.DoCleanupExpired;
var
  LNow: TDateTime;
  LKey: string;
  LKeysToRemove: TList<string>;
  LInfo: TClientRateLimitInfo;
begin
  LNow := Now;
  LKeysToRemove := TList<string>.Create;
  try
    FLock.Acquire;
    try
      for LKey in FBuckets.Keys do
      begin
        if FBuckets.TryGetValue(LKey, LInfo) and (LNow > LInfo.ResetTime) then
          LKeysToRemove.Add(LKey);
      end;

      for LKey in LKeysToRemove do
        FBuckets.Remove(LKey);
    finally
      FLock.Release;
    end;
  finally
    LKeysToRemove.Free;
  end;
end;

procedure THorseRateLimitMemoryStorage.SetOnCleanupError(AProc: TOnCleanupErrorProc);
begin
  FOnCleanupError := AProc;
end;

{ THorseRateLimitConfig }

class function THorseRateLimitConfig.Default: THorseRateLimitConfig;
begin
  Result.FLimit := 60;
  Result.FWindowSeconds := 60;
  Result.FStorage := nil;
  Result.FKeyGenerator := nil;
  Result.FErrorMessage := 'Too Many Requests. Please try again later.';
  Result.FAlgorithm := rlaFixedWindow;
  Result.FTrustProxy := False;
  Result.FProxyHeader := 'X-Forwarded-For';
  Result.FSkipProc := nil;
  Result.FWhitelist := nil;
  Result.FBlacklist := nil;
  Result.FOnLimitReached := nil;
  Result.FOnError := nil;
  Result.FOnCleanupError := nil;
end;

function THorseRateLimitConfig.Limit(ALimit: Integer): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FLimit := ALimit;
end;

function THorseRateLimitConfig.WindowSeconds(AWindowSeconds: Integer): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FWindowSeconds := AWindowSeconds;
end;

function THorseRateLimitConfig.Storage(const AStorage: IHorseRateLimitStorage): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FStorage := AStorage;
end;

function THorseRateLimitConfig.KeyGenerator(AKeyGenerator: TKeyGeneratorProc): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FKeyGenerator := AKeyGenerator;
end;

function THorseRateLimitConfig.ErrorMessage(const AMessage: string): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FErrorMessage := AMessage;
end;

function THorseRateLimitConfig.Algorithm(AAlgorithm: TRateLimitAlgorithm): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FAlgorithm := AAlgorithm;
end;

function THorseRateLimitConfig.TrustProxy(ATrust: Boolean): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FTrustProxy := ATrust;
end;

function THorseRateLimitConfig.ProxyHeader(const AHeader: string): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FProxyHeader := AHeader;
end;

function THorseRateLimitConfig.SkipWhen(AProc: TSkipProc): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FSkipProc := AProc;
end;

function THorseRateLimitConfig.Whitelist(AIPs: TArray<string>): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FWhitelist := AIPs;
end;

function THorseRateLimitConfig.Blacklist(AIPs: TArray<string>): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FBlacklist := AIPs;
end;

function THorseRateLimitConfig.OnLimitReached(AProc: TOnLimitReachedProc): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FOnLimitReached := AProc;
end;

function THorseRateLimitConfig.OnError(AProc: TOnErrorProc): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FOnError := AProc;
end;

function THorseRateLimitConfig.OnCleanupError(AProc: TOnCleanupErrorProc): THorseRateLimitConfig;
begin
  Result := Self;
  Result.FOnCleanupError := AProc;
end;

{ THorseRateLimit }

class constructor THorseRateLimit.CreateClass;
begin
  FDefaultStorage := THorseRateLimitMemoryStorage.Create;
end;

class function THorseRateLimit.New: THorseCallback;
begin
  Result := New(THorseRateLimitConfig.Default);
end;

class function THorseRateLimit.New(const AConfig: THorseRateLimitConfig): THorseCallback;
var
  LStorage: IHorseRateLimitStorage;
  LStorageEx: IHorseRateLimitStorageEx;
  LConfig: THorseRateLimitConfig;
begin
  LConfig := AConfig;
  if LConfig.FStorage = nil then
    LStorage := FDefaultStorage
  else
    LStorage := LConfig.FStorage;

  if Supports(LStorage, IHorseRateLimitStorageEx, LStorageEx) then
  begin
    LStorageEx.SetOnCleanupError(LConfig.FOnCleanupError);
  end;

  Result :=
    procedure(Req: THorseRequest; Res: THorseResponse; Next: {$IF DEFINED(FPC)}TNextProc{$ELSE}TProc{$ENDIF})
    var
      LKey: string;
      LClientIP: string;
      LInfo: THorseRateLimitInfo;
      LResetSecs: Int64;
      LRetryAfter: Int64;
      LIP: string;
    begin
      // 1. Verificar regras de bypass/skip dinâmico
      if Assigned(LConfig.FSkipProc) and LConfig.FSkipProc(Req) then
      begin
        Next();
        Exit;
      end;

      // Obter o IP real do cliente (aplicando Trust Proxy se configurado)
      LClientIP := '';
      if LConfig.FTrustProxy then
      begin
        LClientIP := Req.RawWebRequest.GetFieldByName(LConfig.FProxyHeader);
        if LClientIP <> '' then
        begin
          if LClientIP.Contains(',') then
            LClientIP := LClientIP.Split([','])[0].Trim;
        end;
      end;
      if LClientIP = '' then
        LClientIP := Req.RawWebRequest.RemoteAddr;

      // 2. Verificar Whitelist
      if Length(LConfig.FWhitelist) > 0 then
      begin
        for LIP in LConfig.FWhitelist do
        begin
          if LIP = LClientIP then
          begin
            Next();
            Exit;
          end;
        end;
      end;

      // 3. Verificar Blacklist
      if Length(LConfig.FBlacklist) > 0 then
      begin
        for LIP in LConfig.FBlacklist do
        begin
          if LIP = LClientIP then
          begin
            Res.Status(THTTPStatus.Forbidden).Send('IP Blocked');
            raise EHorseCallbackInterrupted.Create;
          end;
        end;
      end;

      // Construção da chave de Rate Limit
      if Assigned(LConfig.FKeyGenerator) then
        LKey := LConfig.FKeyGenerator(Req)
      else
      begin
        // Diferencia por método HTTP e Path
        LKey := Req.RawWebRequest.Method + ':' + Req.RawWebRequest.PathInfo + ':' + LClientIP;
      end;

      // Avaliação da taxa
      if LStorageEx <> nil then
        LInfo := LStorageEx.EvaluateEx(LKey, LConfig.FLimit, LConfig.FWindowSeconds, LConfig.FAlgorithm)
      else
        LInfo := LStorage.Evaluate(LKey, LConfig.FLimit, LConfig.FWindowSeconds);

      Res.AddHeader('X-RateLimit-Limit', LInfo.Limit.ToString);
      Res.AddHeader('X-RateLimit-Remaining', LInfo.Remaining.ToString);
      
      // Unix Epoch Timestamp para o reset
      LResetSecs := DateTimeToUnix(LInfo.ResetTime, False);
      Res.AddHeader('X-RateLimit-Reset', LResetSecs.ToString);

      if LInfo.IsBlocked then
      begin
        LRetryAfter := SecondsBetween(LInfo.ResetTime, Now);
        if LRetryAfter < 1 then
          LRetryAfter := 1;
        Res.AddHeader('Retry-After', LRetryAfter.ToString);

        if Assigned(LConfig.FOnLimitReached) then
        begin
          try
            LConfig.FOnLimitReached(Req, Res, LInfo);
          except
            // Silencia para não interromper a resposta do erro em si
          end;
        end;

        if Assigned(LConfig.FOnError) then
          LConfig.FOnError(Req, Res, LInfo, LConfig.FErrorMessage)
        else
          Res.Status(THTTPStatus.TooManyRequests).Send(LConfig.FErrorMessage);

        raise EHorseCallbackInterrupted.Create;
      end;

      Next();
    end;
end;

end.
