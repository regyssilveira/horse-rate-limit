unit Horse.RateLimit.Storage.Redis;

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  {$IF DEFINED(FPC)}
  SysUtils, DateUtils, Classes,
  {$ELSE}
  System.SysUtils, System.DateUtils, System.Classes,
  {$ENDIF}
  Horse.RateLimit;

type
  // Callback genérico para executar scripts Lua no Redis.
  // Deve receber o script Lua, as chaves (KEYS) e os argumentos (ARGV).
  // Deve retornar um array de strings contendo a resposta do script Lua:
  // [0] = Count/CurrentRequests
  // [1] = TTL em segundos
  // [2] = IsBlocked (1 = true, 0 = false)
  TRedisEvalProc = {$IF DEFINED(FPC)}function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>{$ELSE}reference to function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>{$ENDIF};

  THorseRateLimitRedisStorage = class(TInterfacedObject, IHorseRateLimitStorage, IHorseRateLimitStorageEx)
  private
    FEvalProc: TRedisEvalProc;
    FOnCleanupError: TOnCleanupErrorProc;
    function GetFixedWindowScript: string;
    function GetSlidingWindowScript: string;
  public
    constructor Create(AEvalProc: TRedisEvalProc);
    function Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
    function EvaluateEx(const AKey: string; ALimit: Integer; AWindowSeconds: Integer; AAlgorithm: TRateLimitAlgorithm): THorseRateLimitInfo;
    procedure SetOnCleanupError(AProc: TOnCleanupErrorProc);
  end;

implementation

{ THorseRateLimitRedisStorage }

constructor THorseRateLimitRedisStorage.Create(AEvalProc: TRedisEvalProc);
begin
  inherited Create;
  FEvalProc := AEvalProc;
end;

function THorseRateLimitRedisStorage.Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
begin
  Result := EvaluateEx(AKey, ALimit, AWindowSeconds, rlaFixedWindow);
end;

function THorseRateLimitRedisStorage.EvaluateEx(const AKey: string; ALimit: Integer; AWindowSeconds: Integer; AAlgorithm: TRateLimitAlgorithm): THorseRateLimitInfo;
var
  LScript: string;
  LKeys: TArray<string>;
  LArgs: TArray<string>;
  LResult: TArray<string>;
  LNowUnix: Int64;
  LCount: Integer;
  LTTL: Integer;
  LIsBlocked: Boolean;
begin
  Result.Limit := ALimit;
  Result.Remaining := 0;
  Result.ResetTime := IncSecond(Now, AWindowSeconds);
  Result.IsBlocked := False;

  if not Assigned(FEvalProc) then
    Exit;

  try
    SetLength(LKeys, 1);
    LKeys[0] := AKey;

    if AAlgorithm = rlaSlidingWindow then
    begin
      LScript := GetSlidingWindowScript;
      LNowUnix := DateTimeToUnix(Now, False);

      SetLength(LArgs, 3);
      LArgs[0] := LNowUnix.ToString;
      LArgs[1] := AWindowSeconds.ToString;
      LArgs[2] := ALimit.ToString;
    end
    else
    begin
      LScript := GetFixedWindowScript;

      SetLength(LArgs, 2);
      LArgs[0] := ALimit.ToString;
      LArgs[1] := AWindowSeconds.ToString;
    end;

    LResult := FEvalProc(LScript, LKeys, LArgs);

    if Length(LResult) >= 3 then
    begin
      LCount := LResult[0].ToInteger;
      LTTL := LResult[1].ToInteger;
      LIsBlocked := LResult[2] = '1';

      if LTTL < 0 then
        LTTL := AWindowSeconds;

      Result.Remaining := ALimit - LCount;
      if Result.Remaining < 0 then
        Result.Remaining := 0;

      Result.ResetTime := IncSecond(Now, LTTL);
      Result.IsBlocked := LIsBlocked;
    end;
  except
    on E: Exception do
    begin
      if Assigned(FOnCleanupError) then
      begin
        try
          FOnCleanupError(E);
        except
          // Silencia para não quebrar a chamada principal
        end;
      end;
      // Sob erro de comunicação do Redis, por padrão de fail-open ou fail-closed,
      // adotamos fail-open para não indisponibilizar a API se o Redis cair
      Result.Remaining := ALimit;
      Result.IsBlocked := False;
    end;
  end;
end;

procedure THorseRateLimitRedisStorage.SetOnCleanupError(AProc: TOnCleanupErrorProc);
begin
  FOnCleanupError := AProc;
end;

function THorseRateLimitRedisStorage.GetFixedWindowScript: string;
begin
  Result :=
    'local key = KEYS[1] ' +
    'local limit = tonumber(ARGV[1]) ' +
    'local window = tonumber(ARGV[2]) ' +
    'local current = redis.call("get", key) ' +
    'if current and tonumber(current) > limit then ' +
    '    local ttl = redis.call("ttl", key) ' +
    '    return {tostring(current), tostring(ttl), "1"} ' +
    'end ' +
    'local newVal = redis.call("incr", key) ' +
    'if newVal == 1 then ' +
    '    redis.call("expire", key, window) ' +
    'end ' +
    'local ttl = redis.call("ttl", key) ' +
    'local blocked = "0" ' +
    'if newVal > limit then ' +
    '    blocked = "1" ' +
    'end ' +
    'return {tostring(newVal), tostring(ttl), blocked}';
end;

function THorseRateLimitRedisStorage.GetSlidingWindowScript: string;
begin
  Result :=
    'local key = KEYS[1] ' +
    'local now = tonumber(ARGV[1]) ' +
    'local window = tonumber(ARGV[2]) ' +
    'local limit = tonumber(ARGV[3]) ' +
    'local clearBefore = now - window ' +
    'redis.call("zremrangebyscore", key, 0, clearBefore) ' +
    'local currentRequests = redis.call("zcard", key) ' +
    'if currentRequests < limit then ' +
    '    redis.call("zadd", key, now, now) ' +
    '    redis.call("expire", key, window) ' +
    '    return {tostring(currentRequests + 1), tostring(window), "0"} ' +
    'else ' +
    '    local ttl = redis.call("ttl", key) ' +
    '    return {tostring(currentRequests), tostring(ttl), "1"} ' +
    'end';
end;

end.
