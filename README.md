# Horse Rate Limit

Middleware de controle de limite de requisições (*Rate Limiting*) para o framework **Horse**. 
Projetado para ser de alta performance, thread-safe, com suporte a armazenamento distribuído (Redis), limpeza assíncrona em background e compatível tanto com Delphi quanto com Lazarus/Free Pascal (FPC).

---

## 🚀 Recursos e Comparativo de Ecossistemas

O **Horse Rate Limit** foi desenvolvido seguindo as melhores práticas e padrões arquiteturais das plataformas web mais robustas do mercado moderno. Veja abaixo como ele se compara com as soluções de referência em outros ecossistemas:

| Funcionalidade | Express Rate Limit (Node.js) | ASP.NET Core (C# / .NET) | **Horse Rate Limit (Delphi/FPC)** |
| :--- | :---: | :---: | :---: |
| **Algoritmo de Janela Fixa** | Sim | Sim | **Sim** |
| **Algoritmo de Janela Deslizante** | Sim | Sim | **Sim** (Sliding Window Counter) |
| **Armazenamento Distribuído (Redis)** | Sim | Sim | **Sim** (Lua atômico e desacoplado) |
| **Prevenção de IP Spoofing (Trust Proxy)** | Sim | Não nativo | **Sim** (com `ProxyHeader` customizável) |
| **Bypass Dinâmico (Skip)** | Sim | Sim | **Sim** (via `SkipWhen`) |
| **Listas de IP (Whitelist / Blacklist)** | Sim (via addons) | Não nativo | **Sim** (com suporte a **notação CIDR**) |
| **Ocultação e Renomeação de Headers** | Sim | Sim | **Sim** (via `ExposeHeaders` e customizadores) |
| **Erros Estruturados (responder em JSON)** | Sim | Sim | **Sim** (via callback `OnError`) |
| **Telemetria / APM Hooks** | Sim | Sim | **Sim** (via callback `OnMetricsReport`) |
| **Cleanup Assíncrono (Thread-safety)** | Nativo | Nativo | **Sim** (via `TCleanupThread` em background) |

---

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

Você pode configurar limites personalizados, janelas de tempo, algoritmos de rate limiting e mensagens de erro através da estrutura fluente `THorseRateLimitConfig`:

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

#### 🙈 Customização e Ocultação de Cabeçalhos
Para segurança por obscuridade ou conformidade com padrões organizacionais, você pode renomear ou ocultar os cabeçalhos de limite de taxa inteiramente:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .ExposeHeaders(False)                         // Oculta os cabeçalhos X-RateLimit-* da resposta HTTP
    // OU renomeia os cabeçalhos caso decida expô-los:
    .HeaderLimitName('Limit-Maximo')
    .HeaderRemainingName('Limit-Restante')
    .HeaderResetName('Limit-Reset-Unix')
));
```

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

O middleware permite definir listas de permissões, bloqueios permanentes ou desvios dinâmicos por código. 

### Validação de IPs Individuais e Faixas CIDR (Subredes)
O Whitelist e o Blacklist oferecem suporte nativo a faixas de IP usando notações CIDR (tanto IPv4 quanto IPv6):

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    // IPs individuais ou blocos CIDR completos na Whitelist (nunca sofrem limite de taxa)
    .Whitelist(['127.0.0.1', '10.0.0.0/8', 'fe80::/10'])
    // IPs individuais ou blocos CIDR na Blacklist (são bloqueados imediatamente com 403 Forbidden)
    .Blacklist(['192.168.10.50', '192.168.1.0/24']) 
    // Ignora dinamicamente se a condição for atendida (ex: baseando-se em chaves de bypass)
    .SkipWhen(                                    
      function(Req: THorseRequest): Boolean
      begin
        Result := Req.Headers['X-App-Service'] = 'internal';
      end)
));
```

---

## 🔔 Callbacks de Resposta Customizada e Auditoria

Você pode interceptar as falhas de limite para registrar logs/auditorias ou formatar a resposta de erro em padrões estruturados como **JSON**:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .Limit(100)
    .OnLimitReached(                              // Callback para auditoria/logs
      procedure(Req: THorseRequest; Res: THorseResponse; const Info: THorseRateLimitInfo)
      begin
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

## 📊 Telemetria de Métricas para APMs
Para monitorar o consumo e o volume de requisições bloqueadas em ferramentas de SRE (como Prometheus, Datadog ou OpenTelemetry), você pode capturar as informações em tempo real no callback de métricas:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .OnMetricsReport(
      procedure(const Info: THorseRateLimitMetricInfo)
      begin
        // Exemplo: Incrementar contadores no middleware horse-prometheus ou logar métricas
        if Info.IsBlocked then
          IncrementarMetricaBloqueio(Info.Path, Info.ClientIP)
        else
          RegistrarConsumoTaxa(Info.Path, Info.Remaining);
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
  MeuClienteRedis;

begin
  THorse.Use(THorseRateLimit.New(
    THorseRateLimitConfig.Default
      .Limit(100)
      .WindowSeconds(60)
      .Algorithm(rlaSlidingWindow) // Suporta tanto Fixed quanto Sliding Window no Redis!
      .Storage(THorseRateLimitRedisStorage.Create(
        function(const AScript: string; const AKeys: TArray<string>; const AArgs: TArray<string>): TArray<string>
        begin
          Result := MeuClienteRedisGlobal.Eval(AScript, AKeys, AArgs);
        end))
  ));

  THorse.Listen(9000);
end.
```

### 🔌 Adaptadores Redis Opcionais Prontos
Se você estiver utilizando uma das duas bibliotecas Redis populares descritas abaixo, pode usar os adaptadores prontos e pré-configurados incluídos na pasta `src` para injetar o callback de Eval automaticamente:

#### Opção A: Usando a biblioteca `szisa/redis-delphi`
```delphi
uses
  Horse,
  Horse.RateLimit,
  Horse.RateLimit.Storage.Redis,
  Horse.RateLimit.Storage.Redis.Szisa, // Importa o adaptador do szisa
  Redis.Client; // Cliente do szisa

var
  LClient: IRedisClient;
begin
  LClient := TRedisClient.Create('localhost', 6379);

  THorse.Use(THorseRateLimit.New(
    THorseRateLimitConfig.Default
      .Storage(THorseRateLimitRedisStorage.Create(CreateSzisaEvalProc(LClient)))
  ));
  
  THorse.Listen(9000);
end.
```

#### Opção B: Usando a biblioteca nativa `Redis.Client` da Embarcadero (RAD Studio Enterprise)
```delphi
uses
  Horse,
  Horse.RateLimit,
  Horse.RateLimit.Storage.Redis,
  Horse.RateLimit.Storage.Redis.Client, // Importa o adaptador nativo
  Redis.Client; // TRedisClient da Embarcadero

var
  LClient: TRedisClient;
begin
  LClient := TRedisClient.Create('localhost', 6379);

  THorse.Use(THorseRateLimit.New(
    THorseRateLimitConfig.Default
      .Storage(THorseRateLimitRedisStorage.Create(CreateDelphiRedisEvalProc(LClient)))
  ));
  
  THorse.Listen(9000);
end.
```

---

## 📄 Licença

Licenciado sob a licença [MIT](LICENSE).
