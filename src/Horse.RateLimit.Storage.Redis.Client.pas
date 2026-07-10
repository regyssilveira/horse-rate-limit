unit Horse.RateLimit.Storage.Redis.Client;

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
  Redis.Client, // Unit oficial da Embarcadero
  Redis.Net,
  Horse.RateLimit.Storage.Redis;

function CreateDelphiRedisEvalProc(const AClient: TRedisClient): TRedisEvalProc;

implementation

function CreateDelphiRedisEvalProc(const AClient: TRedisClient): TRedisEvalProc;
begin
  Result :=
    function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>
    var
      LRes: TRedisResult;
      LArray: TArray<string>;
      I: Integer;
    begin
      LRes := AClient.Eval(AScript, AKeys, AArgs);
      
      SetLength(LArray, LRes.Value.Count);
      for I := 0 to LRes.Value.Count - 1 do
        LArray[I] := LRes.Value.Items[I].AsString;
        
      Result := LArray;
    end;
end;

end.
