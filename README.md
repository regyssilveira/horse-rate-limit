# Horse Rate Limit

Middleware de controle de limite de requisições (*Rate Limiting*) para o framework **Horse**. 
Projetado para ser de alta performance, thread-safe, com limpeza assíncrona em background e compatível tanto com Delphi quanto com Lazarus/Free Pascal (FPC).

## ⚙️ Instalação

A instalação é simples e feita usando o gerenciador de pacotes [`boss`](https://github.com/HashLoad/boss):

```sh
boss install github.com/regyssilveira/horse-rate-limit
```

---

## ⚡️ Início rápido

```delphi
uses
  Horse,
  Horse.RateLimit;

begin
  // Usa a configuração padrão: 60 requisições por minuto por IP do cliente (Fixed Window)
  THorse.Use(THorseRateLimit.New);

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);
end.
```

---

## 🔧 Configurações Avançadas do Middleware

Você pode configurar o middleware de acordo com as necessidades da sua aplicação através da estrutura fluente `THorseRateLimitConfig`:

```delphi
uses
  Horse,
  Horse.RateLimit;

begin
  THorse.Use(THorseRateLimit.New(
    THorseRateLimitConfig.Default
      .Limit(10)                       // Máximo de 10 requisições
      .WindowSeconds(10)               // Janela de 10 segundos
      .Algorithm(rlaSlidingWindow)     // Algoritmo: rlaFixedWindow ou rlaSlidingWindow
      .ErrorMessage('Muitas requisições. Tente novamente mais tarde.')
  ));

  THorse.Listen(9000);
end.
```

### Cabeçalhos de Resposta (Headers)
Em cada resposta HTTP, o middleware adiciona automaticamente os cabeçalhos padrão do mercado:
- `X-RateLimit-Limit`: O limite total de requisições permitido na janela.
- `X-RateLimit-Remaining`: O número de requisições restantes na janela atual.
- `X-RateLimit-Reset`: O timestamp Unix indicando quando o limite será reiniciado.
- `Retry-After`: Adicionado apenas em respostas `429 Too Many Requests`, indicando em segundos o tempo restante de espera obrigatório antes da próxima requisição.

---

## 🛡️ Segurança de IP & Trust Proxy
Ao rodar sua aplicação atrás de proxies reversos ou CDNs (como Nginx, Apache, Cloudflare, AWS ALB), o IP do cliente real é encaminhado em cabeçalhos HTTP. 
> [!CAUTION]
> Ler cabeçalhos de proxy sem ativar a verificação segura expõe sua aplicação a **IP Spoofing** (um atacante pode forjar o cabeçalho IP e burlar o Rate Limit).

Ative o **Trust Proxy** para sanitizar cabeçalhos de proxy de forma segura:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .TrustProxy(True)                            // Habilita a confiança no proxy
    .ProxyHeader('CF-Connecting-IP')             // Lê o cabeçalho do Cloudflare (ou 'X-Forwarded-For')
));
```

---

## 🟢 Whitelist, Blacklist e Skip (Bypass)

O middleware permite definir listas de permissões, bloqueios permanentes ou desvios dinâmicos por código:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .Whitelist(['127.0.0.1', '10.0.0.5'])          // IPs que NUNCA serão limitados
    .Blacklist(['192.168.1.100'])                 // IPs bloqueados permanentemente (retorna 403 Forbidden)
    .SkipWhen(                                    // Ignora dinamicamente se a condição for atendida
      function(Req: THorseRequest): Boolean
      begin
        Result := Req.Headers['X-App-Service'] = 'internal';
      end)
));
```

---

## 🔔 Callbacks de Resposta Customizada e Auditoria

Você pode interceptar as falhas de limite para registrar logs/auditorias ou formatar a resposta de erro em padrões como **JSON**:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .Limit(100)
    .OnLimitReached(                              // Callback para auditoria/logs
      procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo)
      begin
        // Registre no seu sistema de logs (ex: Graylog, Datadog)
        Writeln('IP Bloqueado por limite de taxa: ' + Req.RawWebRequest.RemoteAddr);
      end)
    .OnError(                                     // Formata a resposta HTTP de erro customizada
      procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo; const ErrorMsg: string)
      begin
        Res.Status(THTTPStatus.TooManyRequests)
          .RawWebResponse.ContentType := 'application/json';
        Res.Send('{"error": "too_many_requests", "limit": ' + Info.Limit.ToString + '}');
      end)
));
```

---

## 💾 Limpeza Assíncrona do Storage em Memória

O cleanup do storage em memória padrão (`THorseRateLimitMemoryStorage`) roda de forma assíncrona em background para que as requisições normais não sofram lentidão de varredura.
Para monitorar possíveis erros nessa thread em background, você pode assinar o evento `OnCleanupError`:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .OnCleanupError(
      procedure(E: Exception)
      begin
        Writeln('Erro na thread de cleanup: ' + E.Message);
      end)
));
```

---

## 🔌 Armazenamento Distribuído com Redis (`THorseRateLimitRedisStorage`)

Para aplicações enterprise com múltiplos servidores balanceados (cluster), você deve usar o Redis para centralizar o estado do Rate Limiting. O repositório fornece a unit opcional `Horse.RateLimit.Storage.Redis.pas` contendo a implementação.

Para evitar dependências rígidas de bibliotecas específicas de Redis no Delphi/Lazarus, o storage é **desacoplado** e exige apenas a injeção do callback para executar scripts Lua (`EVAL`) no seu cliente Redis de escolha:

```delphi
uses
  Horse,
  Horse.RateLimit,
  Horse.RateLimit.Storage.Redis,
  MeuClienteRedis; // O cliente Redis que você usa na sua aplicação

begin
  THorse.Use(THorseRateLimit.New(
    THorseRateLimitConfig.Default
      .Limit(100)
      .WindowSeconds(60)
      .Algorithm(rlaSlidingWindow) // Suporta tanto Fixed quanto Sliding Window no Redis!
      .Storage(THorseRateLimitRedisStorage.Create(
        function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>
        begin
          // Adapte aqui para chamar a execução de script LUA do seu componente Redis
          // Exemplo genérico:
          Result := MeuClienteRedisGlobal.Eval(AScript, AKeys, AArgs);
        end))
  ));

  THorse.Listen(9000);
end.
```

---

## 📄 Licença

Licenciado sob a licença [MIT](LICENSE).
