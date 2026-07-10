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
  THorseRateLimitInfo = record
    Limit: Integer;
    Remaining: Integer;
    ResetTime: TDateTime;
    IsBlocked: Boolean;
  end;

  IHorseRateLimitStorage = interface
    ['{620F9CC2-4A3C-4C7C-BA80-7C000674C783}']
    function Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
  end;

  TClientRateLimitInfo = record
    Count: Integer;
    ResetTime: TDateTime;
  end;

  THorseRateLimitMemoryStorage = class(TInterfacedObject, IHorseRateLimitStorage)
  private
    FBuckets: TDictionary<string, TClientRateLimitInfo>;
    FLock: TCriticalSection;
    FLastCleanup: TDateTime;
    procedure CleanupExpired;
  public
    constructor Create;
    destructor Destroy; override;
    function Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
  end;

  TKeyGeneratorProc = {$IF DEFINED(FPC)}TFunc<THorseRequest, string>{$ELSE}reference to function(Req: THorseRequest): string{$ENDIF};

  THorseRateLimitConfig = record
  private
    FLimit: Integer;
    FWindowSeconds: Integer;
    FStorage: IHorseRateLimitStorage;
    FKeyGenerator: TKeyGeneratorProc;
    FErrorMessage: string;
  public
    class function Default: THorseRateLimitConfig; static;
    function Limit(ALimit: Integer): THorseRateLimitConfig;
    function WindowSeconds(AWindowSeconds: Integer): THorseRateLimitConfig;
    function Storage(const AStorage: IHorseRateLimitStorage): THorseRateLimitConfig;
    function KeyGenerator(AKeyGenerator: TKeyGeneratorProc): THorseRateLimitConfig;
    function ErrorMessage(const AMessage: string): THorseRateLimitConfig;
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

{ THorseRateLimitMemoryStorage }

constructor THorseRateLimitMemoryStorage.Create;
begin
  inherited Create;
  FBuckets := TDictionary<string, TClientRateLimitInfo>.Create;
  FLock := TCriticalSection.Create;
  FLastCleanup := Now;
end;

destructor THorseRateLimitMemoryStorage.Destroy;
begin
  FBuckets.Free;
  FLock.Free;
  inherited Destroy;
end;

function THorseRateLimitMemoryStorage.Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
var
  LInfo: TClientRateLimitInfo;
  LNow: TDateTime;
begin
  LNow := Now;
  FLock.Acquire;
  try
    // Limpeza passiva de itens expirados a cada 5 minutos
    if MinutesBetween(LNow, FLastCleanup) >= 5 then
      CleanupExpired;

    if FBuckets.TryGetValue(AKey, LInfo) then
    begin
      if LNow > LInfo.ResetTime then
      begin
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
      LInfo.ResetTime := IncSecond(LNow, AWindowSeconds);
    end;

    FBuckets.AddOrSetValue(AKey, LInfo);

    Result.Limit := ALimit;
    Result.Remaining := ALimit - LInfo.Count;
    if Result.Remaining < 0 then
      Result.Remaining := 0;
    Result.ResetTime := LInfo.ResetTime;
    Result.IsBlocked := LInfo.Count > ALimit;
  finally
    FLock.Release;
  end;
end;

procedure THorseRateLimitMemoryStorage.CleanupExpired;
var
  LNow: TDateTime;
  LKey: string;
  LKeysToRemove: TList<string>;
  LInfo: TClientRateLimitInfo;
begin
  LNow := Now;
  LKeysToRemove := TList<string>.Create;
  try
    for LKey in FBuckets.Keys do
    begin
      if FBuckets.TryGetValue(LKey, LInfo) and (LNow > LInfo.ResetTime) then
        LKeysToRemove.Add(LKey);
    end;

    for LKey in LKeysToRemove do
      FBuckets.Remove(LKey);
  finally
    LKeysToRemove.Free;
  end;
  FLastCleanup := LNow;
end;

{ THorseRateLimitConfig }

class function THorseRateLimitConfig.Default: THorseRateLimitConfig;
begin
  Result.FLimit := 60;
  Result.FWindowSeconds := 60;
  Result.FStorage := nil;
  Result.FKeyGenerator := nil;
  Result.FErrorMessage := 'Too Many Requests. Please try again later.';
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
  LConfig: THorseRateLimitConfig;
begin
  LConfig := AConfig;
  if LConfig.FStorage = nil then
    LStorage := FDefaultStorage
  else
    LStorage := LConfig.FStorage;

  Result :=
    procedure(Req: THorseRequest; Res: THorseResponse; Next: {$IF DEFINED(FPC)}TNextProc{$ELSE}TProc{$ENDIF})
    var
      LKey: string;
      LInfo: THorseRateLimitInfo;
      LResetSecs: Int64;
      LRetryAfter: Int64;
    begin
      if Assigned(LConfig.FKeyGenerator) then
        LKey := LConfig.FKeyGenerator(Req)
      else
      begin
        LKey := Req.RawWebRequest.GetFieldByName('X-Forwarded-For');
        if LKey = '' then
          LKey := Req.RawWebRequest.RemoteAddr;
        LKey := Req.RawWebRequest.PathInfo + ':' + LKey;
      end;

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
        Res.Status(THTTPStatus.TooManyRequests).Send(LConfig.FErrorMessage);
        raise EHorseCallbackInterrupted.Create;
      end;

      Next();
    end;
end;

end.
