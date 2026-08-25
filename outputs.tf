output "api_gateway_url" {
  description = "URL base da solucao. Porta de entrada para tudo."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "endpoint_autenticacao" {
  description = "Onde obter o token, informando o CPF"
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/auth"
}

output "load_balancer_destino" {
  description = "Load Balancer da aplicacao, descoberto por tag do Kubernetes"
  value       = data.aws_lb.api.dns_name
}

output "como_testar" {
  description = "Fluxo completo em dois comandos"
  value       = <<-EOT
    # 1. Obter o token
    curl -X POST ${aws_apigatewayv2_api.main.api_endpoint}/auth \
      -H "content-type: application/json" \
      -d '{"cpf":"SEU_CPF_CADASTRADO"}'

    # 2. Usar o token numa rota protegida
    curl ${aws_apigatewayv2_api.main.api_endpoint}/api/Clientes \
      -H "Authorization: Bearer SEU_TOKEN"

    # 3. Sem token, deve retornar 401
    curl -i ${aws_apigatewayv2_api.main.api_endpoint}/api/Clientes
  EOT
}
