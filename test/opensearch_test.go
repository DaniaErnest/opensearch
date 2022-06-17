package test

import (
	"testing"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"time"
	"fmt"
	http_helper "github.com/gruntwork-io/terratest/modules/http-helper"
)

func TestTerraformOpensearchExample(t *testing.T) {
	
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		// Set the path to the Terraform code that will be tested.
		TerraformDir: "../example",
        Vars:  map[string]interface{} {
            "cluster_domain": "infra-dev.codainfra-staging.com",
        },
	})

	// Clean up resources with "terraform destroy" at the end of the test.
	defer terraform.Destroy(t, terraformOptions)

	// Run "terraform init" and "terraform apply". Fail the test if there are any errors.
	terraform.InitAndApply(t, terraformOptions)

	// Run `terraform output` to get the values of output variables and check they have the expected values.
	kibanaEndpoint := terraform.Output(t, terraformOptions, "kibana_endpoint")

	// Make an HTTP request to the instance and make sure we get back a 200 OK with the body "Hello, World!"
	url := fmt.Sprintf("http://%s", kibanaEndpoint)
	http_helper.HttpGetWithRetry(t, url, nil, 200, "kibana", 30, 5*time.Second)

}