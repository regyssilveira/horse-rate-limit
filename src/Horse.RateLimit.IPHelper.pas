unit Horse.RateLimit.IPHelper;

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  {$IF DEFINED(FPC)}
  SysUtils, Classes;
  {$ELSE}
  System.SysUtils, System.Classes;
  {$ENDIF}

type
  TIPv6Bytes = array[0..15] of Byte;

function ParseIPv4(const AIP: string; out AIPInt: Cardinal): Boolean;
function ParseIPv6(const AIP: string; out AIPBytes: TIPv6Bytes): Boolean;
function IsIPInCIDR(const AIP, ACIDR: string): Boolean;

implementation

function ParseIPv4(const AIP: string; out AIPInt: Cardinal): Boolean;
var
  LParts: TArray<string>;
  LByte: Integer;
  I: Integer;
begin
  Result := False;
  LParts := AIP.Split(['.']);
  if Length(LParts) <> 4 then
    Exit;
    
  AIPInt := 0;
  for I := 0 to 3 do
  begin
    if not TryStrToInt(LParts[I], LByte) then
      Exit;
    if (LByte < 0) or (LByte > 255) then
      Exit;
    AIPInt := (AIPInt shl 8) or Cardinal(LByte);
  end;
  Result := True;
end;

function ParseIPv6(const AIP: string; out AIPBytes: TIPv6Bytes): Boolean;
var
  LCleanIP: string;
  LSplit: TArray<string>;
  LLeftParts, LRightParts: TArray<string>;
  LFinalParts: TArray<string>;
  I, J, LCount, LMissing: Integer;
  LVal: Integer;
begin
  Result := False;
  FillChar(AIPBytes, SizeOf(AIPBytes), 0);
  
  LCleanIP := AIP.Trim;
  if LCleanIP = '::' then
  begin
    Result := True;
    Exit;
  end;

  I := LCleanIP.IndexOf('::');
  if I >= 0 then
  begin
    LLeftParts := LCleanIP.Substring(0, I).Split([':']);
    LRightParts := LCleanIP.Substring(I + 2).Split([':']);
    
    if (Length(LLeftParts) = 1) and (LLeftParts[0] = '') then
      SetLength(LLeftParts, 0);
    if (Length(LRightParts) = 1) and (LRightParts[0] = '') then
      SetLength(LRightParts, 0);

    LMissing := 8 - (Length(LLeftParts) + Length(LRightParts));
    if LMissing < 0 then
      Exit;

    SetLength(LFinalParts, 8);
    LCount := 0;
    
    for J := 0 to High(LLeftParts) do
    begin
      LFinalParts[LCount] := LLeftParts[J];
      Inc(LCount);
    end;
    
    for J := 1 to LMissing do
    begin
      LFinalParts[LCount] := '0';
      Inc(LCount);
    end;
    
    for J := 0 to High(LRightParts) do
    begin
      LFinalParts[LCount] := LRightParts[J];
      Inc(LCount);
    end;
  end
  else
  begin
    LFinalParts := LCleanIP.Split([':']);
    if Length(LFinalParts) <> 8 then
      Exit;
  end;

  for I := 0 to 7 do
  begin
    if LFinalParts[I] = '' then
      LVal := 0
    else
    begin
      if not TryStrToInt('$' + LFinalParts[I], LVal) then
        Exit;
      if (LVal < 0) or (LVal > $FFFF) then
        Exit;
    end;
    AIPBytes[I * 2] := Byte(LVal shr 8);
    AIPBytes[I * 2 + 1] := Byte(LVal and $FF);
  end;
  
  Result := True;
end;

function IsIPInCIDR(const AIP, ACIDR: string): Boolean;
var
  LParts: TArray<string>;
  LSubnetIP: string;
  LMaskBits: Integer;
  LIP4, LSubnet4: Cardinal;
  LIP6, LSubnet6: TIPv6Bytes;
  LBytesToCheck, LBitsToCheck: Integer;
  LMask: Byte;
  I: Integer;
begin
  Result := False;
  
  LParts := ACIDR.Split(['/']);
  if Length(LParts) <> 2 then
    Exit;
    
  LSubnetIP := LParts[0];
  if not TryStrToInt(LParts[1], LMaskBits) then
    Exit;
    
  if LSubnetIP.Contains('.') then
  begin
    if (LMaskBits < 0) or (LMaskBits > 32) then
      Exit;
      
    if not ParseIPv4(AIP, LIP4) then
      Exit;
    if not ParseIPv4(LSubnetIP, LSubnet4) then
      Exit;
      
    if LMaskBits = 0 then
    begin
      Result := True;
      Exit;
    end;
      
    if LMaskBits = 32 then
      Result := LIP4 = LSubnet4
    else
      Result := (LIP4 and (Cardinal($FFFFFFFF) shl (32 - LMaskBits))) = 
                (LSubnet4 and (Cardinal($FFFFFFFF) shl (32 - LMaskBits)));
  end
  else if LSubnetIP.Contains(':') then
  begin
    if (LMaskBits < 0) or (LMaskBits > 128) then
      Exit;
      
    if not ParseIPv6(AIP, LIP6) then
      Exit;
    if not ParseIPv6(LSubnetIP, LSubnet6) then
      Exit;
      
    if LMaskBits = 0 then
    begin
      Result := True;
      Exit;
    end;
      
    LBytesToCheck := LMaskBits div 8;
    LBitsToCheck := LMaskBits mod 8;
    
    for I := 0 to LBytesToCheck - 1 do
    begin
      if LIP6[I] <> LSubnet6[I] then
        Exit;
    end;
    
    if LBitsToCheck > 0 then
    begin
      LMask := Byte($FF) shl (8 - LBitsToCheck);
      if (LIP6[LBytesToCheck] and LMask) <> (LSubnet6[LBytesToCheck] and LMask) then
        Exit;
    end;
    
    Result := True;
  end;
end;

end.
