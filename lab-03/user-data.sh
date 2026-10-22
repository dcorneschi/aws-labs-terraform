#!/bin/bash
# Runs once on the source instance. Everything it writes is baked into the AMI,
# so the restored instance in the secondary Region still has it.

imds() {
  local token
  token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  curl -s -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

# Marker: which instance and Region the data was created on
echo "created on $(imds instance-id) in $(imds placement/region) at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/ami-lab-marker

# Helper that prints where the instance is running now (it is in the AMI too)
cat > /usr/local/bin/ami-lab-whereami <<'EOF'
#!/bin/bash
token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
md() { curl -s -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"; }
echo "running on $(md instance-id) in $(md placement/region) from $(md ami-id)"
EOF
chmod +x /usr/local/bin/ami-lab-whereami
