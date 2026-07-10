unit Horse.RateLimit.Storage.Redis.Szisa;

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  {$IF DEFINED(FPC)}
  SysUtils, Classes,
  {$ELSE}
  System.SysUtils, System.Classes,
  {$ENDIF}
  Redis.Client, // Unit da biblioteca szisa/redis-delphi
  Redis.Commons,
  Horse.RateLimit.Storage.Redis;

function CreateSzisaEvalProc(const AClient: IRedisClient): TRedisEvalProc;

implementation

function CreateSzisaEvalProc(const AClient: IRedisClient): TRedisEvalProc;
begin
  Result :=
    function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>
    var
      LRes: IRedisResponse;
      LArray: TArray<string>;
      I: Integer;
    begin
      LRes := AClient.Eval(AScript, AKeys, AArgs);
      
      SetLength(LArray, LRes.AsArray.Count);
      for I := 0 to LRes.AsArray.Count - 1 do
        LArray[I] := LRes.AsArray.Items[I].AsString;
        
      Result := LArray;
    end;
end;

end.
