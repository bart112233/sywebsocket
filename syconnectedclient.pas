unit syconnectedclient;

{ TODO : Exceptions for errors }
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, blcksock, synautil, synsock, ssl_openssl, sha1, base64, websocpackmanager,
  httpheader, websocketframe, websocketmessage;

const
  TIMEOUT = 10000;
  ANSWER_STRING = 'It''s sy Websocket Server';

type

  TOnClientTextMessage = procedure(Sender: TObject; Message: string) of object;
  TOnClientCloseConnect = procedure(Sender: TObject; Reason: integer; Message: string) of object;
  TOnClientBinaryMessage = procedure(Sender: TObject; BinData: TBytes) of object;


  { TsyConnectedClient }

  TsyConnectedClient = class(TThread)
  private
    FCritSection: TRTLCriticalSection;
    FOnClientPing: TOnClientTextMessage;
    FTerminateEvent: PRTLEvent;
    FSock: TTCPBlockSocket;
    FWebSocket: boolean;
    FHandShake: boolean;
    FOnClientTextMessage: TOnClientTextMessage;
    FOnClientBinaryData: TOnClientBinaryMessage;
    FOnClientClose: TOnClientCloseConnect;
    FTag: integer;
    FCookie: string;
    FWebsocketFrame: TWebsockPackManager;
    function MyEncodeBase64(sha1: TSHA1Digest): string;
    procedure Execute; override;
    procedure OnStatus(Sender: TObject; Reason: THookSocketReason; const Value: string);
    function IsWebSocketConnect(AHeader: TStringList): boolean;
    procedure SendHTTPAnswer;
    procedure SendHandShake(ASecWebSocketKey: string);
    function GetWebSocketKey(AHeader: TStringList): string;
    procedure ProcessData;
  public
    constructor Create(hSock: TSocket);
    destructor Destroy; override;
    procedure TerminateThread;

    // комманды отправки
    procedure SendCloseFrame(AReason: integer; AMessage: string);
    procedure SendMessageFrame(AMessage: string);
    procedure SendBinaryFrame(ABinData: TBytes);
    procedure SendPong(AMessage: string);

    property OnClientTextMessage: TOnClientTextMessage read FOnClientTextMessage write FOnClientTextMessage;
    property OnClientBinaryData: TOnClientBinaryMessage read FOnClientBinaryData write FOnClientBinaryData;
    property OnClientClose: TOnClientCloseConnect read FOnClientClose write FOnClientClose;
    property OnClientPing: TOnClientTextMessage read FOnClientPing write FOnClientPing;
    property Tag: integer read FTag write FTag;
  end;

implementation

///////////////////////////////////////////////////
{
 +----------+----------+----------+----------+
 | $00..$7F |          |          |          |
 | $C2..$DF | $80..$BF |          |          |
 | $E0      | $A0..$BF | $80..$BF |          |
 | $E1..$EC | $80..$BF | $80..$BF |          |
 | $ED      | $80..$9F | $80..$BF |          |
 | $EE..$EF | $80..$BF | $80..$BF |          |
 | $F0      | $90..$BF | $80..$BF | $80..$BF |
 | $F1..$F3 | $80..$BF | $80..$BF | $80..$BF |
 | $F4      | $80..$8F | $80..$BF | $80..$BF |
 +----------+----------+----------+----------+
}
///////////////////////////////////////////////////
function IsValidUTF8(AValue: PChar; ALen: integer): boolean;
var
  i, len, n, j: integer;
  c: ^byte;
begin
  Result := False;
  len := ALen;
  i := 0;
  c := @AValue[0];
  while i < len do
  begin
    if (c^ >= $00) and (c^ <= $7f) then
      n := 0
    else if (c^ >= $c2) and (c^ <= $df) then
      n := 1
    else if (c^ = $e0) then
      n := 2
    else if (c^ >= $e1) and (c^ <= $ec) then
      n := 2
    else if (c^ = $ed) then
      n := 2
    else if (c^ >= $ee) and (c^ <= $ef) then
      n := 2
    else if (c^ = $f0) then
      n := 3
    else if (c^ >= $f1) and (c^ <= $f3) then
      n := 3
    else if (c^ = $f4) then
      n := 3
    else
      exit;

    j := 0;
    Inc(i);

    while j < n do
    begin
      if i >= len then
        exit;
      case c^ of
        $c2..$df, $e1..$ec, $ee..$ef, $f1..$f3:
          if not (((c + 1)^ >= $80) and ((c + 1)^ <= $bf)) then
            exit;
        $e0:
          if not (((c + 1)^ >= $a0) and ((c + 1)^ <= $bf)) then
            exit;
        $ed:
          if not (((c + 1)^ >= $80) and ((c + 1)^ <= $9f)) then
            exit;
        $f0:
          if not (((c + 1)^ >= $90) and ((c + 1)^ <= $bf)) then
            exit;
        $f4:
          if not (((c + 1)^ >= $80) and ((c + 1)^ <= $8f)) then
            exit;
        $80..$bf:
          if not (((c + 1)^ >= $80) and ((c + 1)^ <= $bf)) then
            exit;
      end;
      Inc(c);
      Inc(i);
      Inc(j);
    end;
    Inc(c);
  end;
  Result := True;
end;

{ TsyConnectedClient }


function TsyConnectedClient.MyEncodeBase64(sha1: TSHA1Digest): string;
var
  i: integer;
  DecodedStream: TStringStream;
  EncodedStream: TStringStream;
  Encoder: TBase64EncodingStream;
  Output: string;
begin
  EncodedStream := TStringStream.Create('');
  try
    Encoder := TBase64EncodingStream.Create(EncodedStream);
    try
      encoder.WriteBuffer(sha1, length(sha1));
      Encoder.Flush;
      Output := EncodedStream.DataString;
    finally
      FreeAndNil(Encoder);
    end;
  finally
    FreeAndNil(EncodedStream);
  end;
  Result := Output;
end;

procedure TsyConnectedClient.Execute;
var
  s: string;
  HTTPRec: THTTPRecord;
  Header: TStringList;

begin
  FSock.OnStatus := @OnStatus;
  FWebSocket := False;
  FHandShake := False;
  s := FSock.RecvString(TIMEOUT);

  if FSock.LastError <> 0 then
    exit;

  HTTPRec.Parse(s);
  // if not HTTP request then close connection
  if HTTPRec.Protocol <> 'HTTP/1.1' then
    exit;

  // read header
  Header := TStringList.Create;
  try
    repeat
      s := FSock.RecvString(TIMEOUT);
      Header.Add(s);
    until s = '';
    FWebSocket := IsWebSocketConnect(Header);

    if FWebSocket then
    begin
      if not FHandShake then
      begin
        // Handshake with client
        SendHandShake(GetWebSocketKey(Header));
        FHandShake := True;
      end;
    end
    else
    begin
      // Send Answer to browser
      SendHTTPAnswer;
      exit;
    end;
  finally
    FreeAndNil(Header);
  end;
  if FHandShake then
  begin
    ProcessData;
  end;

  TerminateThread;
end;

function TsyConnectedClient.IsWebSocketConnect(AHeader: TStringList): boolean;
var
  s: string;
  headerKey, headerValue: string;
begin
  Result := False;
  for s in AHeader do
  begin
    headerValue := s;
    headerKey := Fetch(headerValue, ':');
    if (LowerCase(headerKey) = 'upgrade') and (LowerCase(headerValue) = 'websocket') then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TsyConnectedClient.SendHTTPAnswer;
var
  AnswerStr: string;
begin
  AnswerStr := ANSWER_STRING;
  FSock.SendString('HTTP/1.0 200' + CRLF);
  FSock.SendString('Content-type: text/html');
  FSock.SendString('Content-length: ' + IntToStr(Length(AnswerStr)) + CRLF);
  FSock.SendString('Date: ' + Rfc822DateTime(now) + CRLF);
  FSock.SendString('Connection: close' + CRLF);
  FSock.SendString('Server: syWebsocket Server' + CRLF);
  FSock.SendString('' + CRLF);
  FSock.SendString(AnswerStr);
end;

procedure TsyConnectedClient.SendHandShake(ASecWebSocketKey: string);
var
  wsValue: string;
  sendStr: string;
begin

  sendstr := 'HTTP/1.1 101 Web Socket Protocol Handshake' + CRLF;
  sendstr := sendstr + 'Server: syWebsocket Server' + CRLF;
  sendstr := sendstr + 'X-Powered-By: syWebSocket Server' + CRLF;
  sendstr := sendstr + 'Connection: Upgrade' + CRLF;



  wsValue := ASecWebSocketKey + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  wsvalue := MyEncodeBase64(SHA1String(wsValue));

  sendstr := sendstr + 'Sec-WebSocket-Accept: ' + wsValue + CRLF;
  sendstr := sendstr + 'Upgrade: websocket' + CRLF;
  FSock.SendString(sendStr + CRLF);
end;


function TsyConnectedClient.GetWebSocketKey(AHeader: TStringList): string;
var
  s: string;
  headerKey, headerValue: string;
begin
  Result := '';
  for s in AHeader do
  begin
    headerValue := s;
    headerKey := Fetch(headerValue, ':');
    if headerKey = 'Sec-WebSocket-Key' then
    begin
      Result := headerValue;
      Exit;
    end;
  end;
end;

procedure TsyConnectedClient.ProcessData;
var
  DataLen: integer;
  DataBuffer: TBytes;
  RcvLen: integer;
  RcvFrame: TMemoryStream;
  wsMessage: TsyWebSocketMessage;
  wsFrame: TsyBaseWebsocketFrame;
  ////
  tmp_s: string;
begin
  // Websocket Loop
  FWebsocketFrame := TWebsockPackManager.Create();
  wsMessage := TsyWebSocketMessage.Create;
  try
    while not Terminated do
    begin
      // get data from socket
      if FSock.CanRead(1000) then
      begin
        DataLen := FSock.WaitingData;
        if DataLen = 0 then
          exit;
        SetLength(DataBuffer, DataLen);
        RcvLen := FSock.RecvBuffer(@DataBuffer[0], DataLen);
        if RcvLen <> DataLen then // need raise exception
          Exit;
        FWebsocketFrame.InsertData(DataBuffer, RcvLen);

        while FWebsocketFrame.Count > 0 do
        begin
          RcvFrame := FWebsocketFrame.pop;

          wsFrame := TsyBaseWebsocketFrame.Create;
          try
            wsFrame.Frame := RcvFrame;

            // if set RSV1-RSV3 bit disconnect with error code 1002
            if wsFrame.Rsv1 or wsFrame.Rsv2 or wsFrame.Rsv3 then
            begin
              SendCloseFrame(1002, '');
              Exit;
            end;

            if ((wsFrame.OpCode > optBinary) and (wsFrame.OpCode < optCloseConnect)) or (wsFrame.OpCode > optPong) then
            begin
              SendCloseFrame(1002, '');
              Exit;
            end;


            case wsFrame.Opcode of
              optPing, optPong, optCloseConnect: // not fragmented frame
              begin
                case wsFrame.OpCode of
                  optPing:
                  begin
                    if wsFrame.PayloadLen > 125 then // payload <=125
                    begin
                      SendCloseFrame(1002, '');
                      exit;
                    end;
                    if not wsFrame.Fin then   // no fragmentation
                    begin
                      SendCloseFrame(1002, '');
                      exit;
                    end;
                    if Assigned(OnClientPing) then
                    begin
                      SendPong(wsFrame.MessageStr);
                      OnClientPing(self, wsFrame.MessageStr);
                    end;
                  end;
                  optPong: // we can not send ping. And if we get Pong we disconnect
                  begin
                    if not wsFrame.Fin then   // no fragmentation
                    begin
                      SendCloseFrame(1002, '');
                      exit;
                    end;
                  end;
                  optCloseConnect:
                  begin
                    SendCloseFrame(wsFrame.Reason, wsFrame.MessageStr);
                    Exit;
                  end;

                end;

              end;
              optText, optBinary, optContinue: // fragmented frame
              begin
                // Copy Payload data to TsyWebsocketMessage

                if not wsMessage.AddData(wsFrame) then
                  exit;  // critical error - Disconnect;
                //                tmp_s := wsMessage.MessageStr;
                if wsMessage.IsReady then
                begin
                  case wsMessage.MessageType of
                    optText: // if Text then send OnClientTextMessage event to parent Thread about new Text message;
                    begin
                      if wsMessage.PayloadLen > 0 then // check valid UTF-8 string
                        if not IsValidUTF8(@wsMessage.BinData[0], wsMessage.PayloadLen) then
                        begin
                          SendCloseFrame(1007, '');
                          exit;
                        end;
                      if Assigned(OnClientTextMessage) then
                        OnClientTextMessage(Self, wsMessage.MessageStr);

                    end;
                    optBinary: // if Text then send OnClientTextMessage event to parent Thread about new Text message;
                      if Assigned(OnClientBinaryData) then
                        OnClientBinaryData(Self, wsMessage.BinData);
                  end;
                end;

              end;
            end;
          finally
            FreeAndNil(wsFrame);
          end;
        end;

        SetLength(DataBuffer, 0);
      end;
    end;
  finally
    FreeAndNil(wsMessage);
    FreeAndNil(FWebsocketFrame);
  end;

end;

constructor TsyConnectedClient.Create(hSock: TSocket);
begin
  //  syLog.Info('Start Client Thread');
  InitCriticalSection(FCritSection);
  FTerminateEvent := RTLEventCreate;
  FSock := TTCPBlockSocket.Create;
  FSock.Socket := hSock;
  FreeOnTerminate := True;
  inherited Create(True);
end;

destructor TsyConnectedClient.Destroy;
begin
  FreeAndNil(FSock);
  RTLeventdestroy(FTerminateEvent);
  DoneCriticalsection(FCritSection);
  inherited Destroy;
end;

procedure TsyConnectedClient.TerminateThread;
begin
  if Terminated then
    exit;
  FSock.CloseSocket;
  Terminate;
  RTLeventSetEvent(FTerminateEvent);
end;

procedure TsyConnectedClient.SendCloseFrame(AReason: integer; AMessage: string);
var
  WFrame: TsyBaseWebsocketFrame;
begin
  EnterCriticalsection(FCritSection);
  try
    WFrame := TsyBaseWebsocketFrame.Create;
    try
      WFrame.Opcode := optCloseConnect;
      WFrame.Mask := False;
      WFrame.Reason := AReason;
      WFrame.MessageStr := AMessage;
      if FSock.CanWrite(1000) then
        FSock.SendBuffer(WFrame.Frame.Memory, WFrame.Frame.Size);
    finally
      FreeAndNil(WFrame);
    end;
  finally
    LeaveCriticalsection(FCritSection);
  end;
  TerminateThread;
end;

procedure TsyConnectedClient.SendMessageFrame(AMessage: string);
var
  WFrame: TsyBaseWebsocketFrame;
begin
  EnterCriticalsection(FCritSection);
  try
    WFrame := TsyBaseWebsocketFrame.Create;
    try
      WFrame.Opcode := optText;
      WFrame.Mask := False;
      WFrame.MessageStr := AMessage;
      if FSock.CanWrite(1000) then
        FSock.SendBuffer(WFrame.Frame.Memory, WFrame.Frame.Size);
    finally
      FreeAndNil(WFrame);
    end;
  finally
    LeaveCriticalsection(FCritSection);
  end;
end;

procedure TsyConnectedClient.SendBinaryFrame(ABinData: TBytes);
var
  WFrame: TsyBaseWebsocketFrame;
  len: integer;
  dt: TBytes;
begin
  EnterCriticalsection(FCritSection);
  try
    len := Length(ABinData);
    WFrame := TsyBaseWebsocketFrame.Create;
    try
      WFrame.Fin := True;
      WFrame.Opcode := optBinary;
      WFrame.Mask := False;

      WFrame.Binary := ABinData;
      if FSock.CanWrite(1000) then
        FSock.SendBuffer(WFrame.Frame.Memory, WFrame.Frame.Size);
    finally
      FreeAndNil(WFrame);
    end;
  finally
    LeaveCriticalsection(FCritSection);
  end;
end;

procedure TsyConnectedClient.SendPong(AMessage: string);
var
  WFrame: TsyBaseWebsocketFrame;
begin
  EnterCriticalsection(FCritSection);
  try
    WFrame := TsyBaseWebsocketFrame.Create;
    try
      WFrame.Opcode := optPong;
      WFrame.Mask := False;
      WFrame.MessageStr := AMessage;
      if FSock.CanWrite(1000) then
        FSock.SendBuffer(WFrame.Frame.Memory, WFrame.Frame.Size);
    finally
      FreeAndNil(WFrame);
    end;
  finally
    LeaveCriticalsection(FCritSection);
  end;
end;

procedure TsyConnectedClient.OnStatus(Sender: TObject; Reason: THookSocketReason; const Value: string);
begin
  case Reason of
    HR_Error:
      TerminateThread;
  end;
end;


end.






