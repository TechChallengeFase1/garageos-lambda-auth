// Autenticacao por CPF do GarageOS.
//
// Um arquivo, duas funcoes Lambda:
//
//   handler     POST /auth   valida o CPF, consulta o cliente no RDS e devolve
//                            um JWT. Roda DENTRO da VPC.
//   authorizer  API Gateway  confere a assinatura do JWT antes de a requisicao
//                            chegar ao cluster. Roda FORA da VPC.
//
// Dependencia externa: apenas `pg`. O JWT e assinado com o modulo `crypto` do
// proprio Node - HS256 e um HMAC-SHA256 sobre "cabecalho.corpo", nada alem
// disso, entao trazer uma biblioteca so para isso nao se justifica.

import crypto from "node:crypto";
import pg from "pg";

// Injetados pelo Terraform. Os valores vem do AWS Secrets Manager, lidos no
// momento do apply - a Lambda esta em subnet privada sem NAT Gateway e nao
// alcancaria a API do Secrets Manager em tempo de execucao.
const JWT_SECRET = process.env.JWT_SECRET_KEY;
const JWT_ISSUER = process.env.JWT_ISSUER;
const JWT_AUDIENCE = process.env.JWT_AUDIENCE;
const EXPIRA_EM = Number(process.env.JWT_EXPIRES_IN_SECONDS ?? 3600);

// ─── JWT HS256 ───────────────────────────────────────────────────────────────

const paraBase64Url = (texto) => Buffer.from(texto).toString("base64url");

function assinarToken(dados, expiraEmSegundos) {
  const agora = Math.floor(Date.now() / 1000);

  const cabecalho = paraBase64Url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const corpo = paraBase64Url(
    JSON.stringify({ ...dados, iat: agora, exp: agora + expiraEmSegundos })
  );

  const assinatura = crypto
    .createHmac("sha256", JWT_SECRET)
    .update(`${cabecalho}.${corpo}`)
    .digest("base64url");

  return `${cabecalho}.${corpo}.${assinatura}`;
}

function verificarToken(token) {
  const partes = token.split(".");
  if (partes.length !== 3) return null;

  const [cabecalho, corpo, assinatura] = partes;

  const esperada = crypto
    .createHmac("sha256", JWT_SECRET)
    .update(`${cabecalho}.${corpo}`)
    .digest("base64url");

  // timingSafeEqual em vez de "===": a comparacao comum sai no primeiro byte
  // diferente, e medir esse tempo permite descobrir a assinatura byte a byte.
  const recebida = Buffer.from(assinatura);
  const calculada = Buffer.from(esperada);
  if (recebida.length !== calculada.length) return null;
  if (!crypto.timingSafeEqual(recebida, calculada)) return null;

  let conteudo;
  try {
    conteudo = JSON.parse(Buffer.from(corpo, "base64url").toString());
  } catch {
    return null;
  }

  const agora = Math.floor(Date.now() / 1000);
  if (conteudo.exp && conteudo.exp < agora) return null;
  if (conteudo.iss !== JWT_ISSUER) return null;
  if (conteudo.aud !== JWT_AUDIENCE) return null;

  return conteudo;
}

// ─── CPF ─────────────────────────────────────────────────────────────────────

function cpfValido(cpf) {
  // 11 digitos, e nao todos iguais - "111.111.111-11" passa no calculo dos
  // digitos verificadores mas nao e um CPF real.
  if (cpf.length !== 11) return false;
  if (/^(\d)\1{10}$/.test(cpf)) return false;

  const digitoVerificador = (base, pesoInicial) => {
    let soma = 0;
    for (let i = 0; i < base.length; i++) {
      soma += Number(base[i]) * (pesoInicial - i);
    }
    const resto = (soma * 10) % 11;
    return resto === 10 ? 0 : resto;
  };

  return (
    digitoVerificador(cpf.slice(0, 9), 10) === Number(cpf[9]) &&
    digitoVerificador(cpf.slice(0, 10), 11) === Number(cpf[10])
  );
}

// ─── Banco ───────────────────────────────────────────────────────────────────

// Fora do handler de proposito: a AWS reaproveita o container entre invocacoes,
// entao o pool sobrevive e a conexao so e aberta na primeira chamada fria.
//
// A configuracao vem das variaveis PGHOST, PGPORT, PGDATABASE, PGUSER e
// PGPASSWORD, que o `pg` le sozinho - evita montar uma URI e ter de escapar
// caracteres especiais da senha.
let pool;

function obterPool() {
  pool ??= new pg.Pool({
    max: 1,
    connectionTimeoutMillis: 5000,
    // O RDS usa certificado da CA da Amazon. Verificar a cadeia exigiria
    // embarcar o bundle da AWS no pacote; a conexao segue criptografada.
    ssl: { rejectUnauthorized: false },
  });
  return pool;
}

async function buscarClientePorCpf(cpf) {
  const { rows } = await obterPool().query(
    'SELECT "Id", "Nome", "Email", "Ativo" FROM "Clientes" WHERE "DocumentoValor" = $1 LIMIT 1',
    [cpf]
  );
  return rows[0] ?? null;
}

// ─── Respostas ───────────────────────────────────────────────────────────────

const responder = (status, corpo) => ({
  statusCode: status,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(corpo),
});

// ─── Handler: emite o token ──────────────────────────────────────────────────

export async function handler(evento) {
  let entrada;
  try {
    entrada = JSON.parse(evento.body || "{}");
  } catch {
    return responder(400, { erro: "Corpo da requisicao nao e um JSON valido." });
  }

  // Aceita "123.456.789-09" ou "12345678909". O banco guarda so digitos.
  const cpf = String(entrada.cpf ?? "").replace(/\D/g, "");

  // 1. Validar o CPF
  if (!cpfValido(cpf)) {
    return responder(400, { erro: "CPF invalido." });
  }

  // 2. Consultar existencia e status do cliente
  let cliente;
  try {
    cliente = await buscarClientePorCpf(cpf);
  } catch (erro) {
    console.error("Falha ao consultar o banco:", erro.message);
    return responder(503, { erro: "Servico de dados indisponivel." });
  }

  if (!cliente) {
    return responder(404, { erro: "Cliente nao encontrado." });
  }

  if (!cliente.Ativo) {
    return responder(403, { erro: "Cliente inativo." });
  }

  // 3. Gerar e devolver o token
  const token = assinarToken(
    {
      sub: cliente.Id,
      name: cliente.Nome,
      email: cliente.Email,
      cpf,
      iss: JWT_ISSUER,
      aud: JWT_AUDIENCE,
    },
    EXPIRA_EM
  );

  return responder(200, {
    accessToken: token,
    tokenType: "Bearer",
    expiresIn: EXPIRA_EM,
    cliente: { id: cliente.Id, nome: cliente.Nome },
  });
}

// ─── Authorizer: valida o token no API Gateway ───────────────────────────────
//
// O HTTP API tem um authorizer JWT nativo, mas ele so funciona com provedores
// OIDC/OAuth2 que expoem um endpoint JWKS. Um token HS256 assinado por esta
// propria Lambda nao tem chave publica para ser buscada - por isso a validacao
// precisa ser feita aqui.
//
// Formato de resposta do modo "simple response" (payload versao 2.0).

export async function authorizer(evento) {
  const cabecalho =
    evento.headers?.authorization ?? evento.headers?.Authorization ?? "";

  const token = cabecalho.replace(/^Bearer\s+/i, "").trim();
  if (!token) return { isAuthorized: false };

  const conteudo = verificarToken(token);
  if (!conteudo) return { isAuthorized: false };

  // Repassado a aplicacao como header, para ela saber quem e o chamador sem
  // precisar decodificar o token de novo.
  return {
    isAuthorized: true,
    context: { clienteId: conteudo.sub, cpf: conteudo.cpf },
  };
}
